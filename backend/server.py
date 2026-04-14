from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field
import os
from dotenv import load_dotenv
from typing import Optional, List, Dict, Any, Tuple
import json
import time
import uuid
from datetime import datetime
import boto3
from botocore.config import Config
from botocore.exceptions import (
    ClientError,
    ConnectTimeoutError,
    ParamValidationError,
    ReadTimeoutError,
)
from context import prompt

# Load environment variables
load_dotenv()

app = FastAPI()

# Configure CORS
origins = os.getenv("CORS_ORIGINS", "http://localhost:3000").split(",")
app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)

# Lambda region (S3, etc.); Bedrock Runtime may use other regions (each has its own quotas).
_lambda_region = os.getenv("AWS_REGION") or os.getenv("DEFAULT_AWS_REGION", "us-east-1")
_bedrock_api_region = os.getenv("BEDROCK_RUNTIME_REGION", "").strip() or _lambda_region

# Bedrock model selection — Q42 https://edwarddonner.com/faq (global Nova 2 Lite inference profile)
BEDROCK_MODEL_ID = os.getenv(
    "BEDROCK_MODEL_ID",
    "global.amazon.nova-2-lite-v1:0",
)

# Per-request caps to reduce Bedrock token usage (helps with daily / burst limits)
_MAX_PRIOR_MESSAGES = int(os.getenv("BEDROCK_MAX_PRIOR_MESSAGES", "10"))
_SYSTEM_MAX_CHARS = int(os.getenv("BEDROCK_SYSTEM_MAX_CHARS", "9000"))
# Keep low so API Gateway (30s max for HTTP API + Lambda) can return 429 detail instead of 503.
_BEDROCK_CONVERSE_MAX_ATTEMPTS = int(os.getenv("BEDROCK_CONVERSE_MAX_ATTEMPTS", "2"))
# Wall-clock budget for trying regional routes (Lambda + API Gateway effectively cap ~30s).
_BEDROCK_ROUTE_TIME_BUDGET_S = float(os.getenv("BEDROCK_ROUTE_TIME_BUDGET_S", "22"))
# Tight timeouts so one slow region does not burn the whole budget.
_BEDROCK_CLIENT_CFG = Config(
    connect_timeout=5,
    read_timeout=12,
    retries={"max_attempts": 1},
)

# Local / demo only: skip Bedrock and return a stub reply (never set on production Lambda).
_BEDROCK_STUB = os.getenv("BEDROCK_STUB_MODE", "").strip().lower() in ("1", "true", "yes")

# Shown on 429 so users find the right Service Quotas (not Data Automation rows)
_BEDROCK_QUOTA_HELP = (
    "In AWS Console → Service Quotas → AWS services → Amazon Bedrock: use the search/filter for "
    "'on-demand', 'Cross-Region inference', 'Invoke', or 'tokens' — those control chat/model calls. "
    "Rows titled Data Automation, Prompt Optimization, etc. do not apply to Converse/InvokeModel. "
    "Optional env BEDROCK_ROUTE_CHAIN (JSON list of {region,modelId}) overrides the default try order. "
    "Reference: https://docs.aws.amazon.com/bedrock/latest/userguide/quotas.html "
)


# Regions where Bedrock documents allow calling the APAC Nova Micro inference profile (apac.*) as source.
_APAC_PROFILE_SOURCE_REGIONS = frozenset(
    {
        "ap-east-2",
        "ap-northeast-1",
        "ap-northeast-2",
        "ap-south-1",
        "ap-south-2",
        "ap-southeast-1",
        "ap-southeast-2",
        "ap-southeast-3",
        "ap-southeast-4",
        "ap-southeast-5",
        "ap-southeast-7",
        "me-central-1",
    }
)


def _bedrock_routes() -> List[Tuple[str, str]]:
    """(Bedrock Runtime region, inference profile id). Each geography's profile must be called from that region's API."""
    raw = os.getenv("BEDROCK_ROUTE_CHAIN", "").strip()
    if raw:
        try:
            data = json.loads(raw)
            return [(str(x["region"]), str(x["modelId"])) for x in data]
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as ex:
            print(f"Ignoring invalid BEDROCK_ROUTE_CHAIN: {ex}")
    primary = (_bedrock_api_region, BEDROCK_MODEL_ID)
    # US Nova 2 Lite often has a separate on-demand pool from APAC/EU global routing (try after primary).
    candidates: List[Tuple[str, str]] = [
        primary,
        ("us-east-1", "us.amazon.nova-2-lite-v1:0"),
        ("eu-west-1", "eu.amazon.nova-micro-v1:0"),
    ]
    if _lambda_region in _APAC_PROFILE_SOURCE_REGIONS:
        candidates.append((_lambda_region, "apac.amazon.nova-micro-v1:0"))
    seen: set[Tuple[str, str]] = set()
    out: List[Tuple[str, str]] = []
    for r in candidates:
        if r not in seen:
            seen.add(r)
            out.append(r)
    return out

# Memory storage configuration
USE_S3 = os.getenv("USE_S3", "false").lower() == "true"
S3_BUCKET = os.getenv("S3_BUCKET", "")
MEMORY_DIR = os.getenv("MEMORY_DIR", "../memory")

# Initialize S3 client if needed
if USE_S3:
    s3_client = boto3.client("s3")


# Request/Response models
class ChatRequest(BaseModel):
    message: str = Field(..., max_length=8000)
    session_id: Optional[str] = None


class ChatResponse(BaseModel):
    response: str
    session_id: str


class Message(BaseModel):
    role: str
    content: str
    timestamp: str


# Memory management functions
def get_memory_path(session_id: str) -> str:
    return f"{session_id}.json"


def load_conversation(session_id: str) -> List[Dict]:
    """Load conversation history from storage"""
    if USE_S3:
        try:
            response = s3_client.get_object(Bucket=S3_BUCKET, Key=get_memory_path(session_id))
            return json.loads(response["Body"].read().decode("utf-8"))
        except ClientError as e:
            if e.response["Error"]["Code"] == "NoSuchKey":
                return []
            raise
    else:
        # Local file storage
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        if os.path.exists(file_path):
            with open(file_path, "r") as f:
                return json.load(f)
        return []


def _inference_config(model_id: str) -> Dict[str, Any]:
    """Nova models reject requests that set both temperature and topP (AWS Converse docs)."""
    mid = model_id.lower()
    if "nova" in mid:
        # Smaller cap = fewer billed output tokens; micro is for short replies
        max_out = 256 if "nova-micro" in mid else 512
        return {"maxTokens": max_out, "temperature": 0.7}
    return {"maxTokens": 2000, "temperature": 0.7, "topP": 0.9}


def _bedrock_system_text() -> str:
    text = prompt().strip()
    if len(text) <= _SYSTEM_MAX_CHARS:
        return text
    return (
        text[: _SYSTEM_MAX_CHARS - 120]
        + "\n\n[Persona context truncated to reduce token usage.]\n"
    )


def _prior_messages_for_converse(conversation: List[Dict]) -> List[Dict[str, str]]:
    """Bedrock Converse requires alternating user/assistant; merge broken runs."""
    merged: List[Dict[str, str]] = []
    tail = conversation[-_MAX_PRIOR_MESSAGES:] if _MAX_PRIOR_MESSAGES > 0 else []
    for msg in tail:
        role = msg.get("role")
        text = (msg.get("content") or "").strip()
        if role not in ("user", "assistant") or not text:
            continue
        if merged and merged[-1]["role"] == role:
            merged[-1]["content"] = f"{merged[-1]['content']}\n\n{text}"
        else:
            merged.append({"role": role, "content": text})
    while merged and merged[-1]["role"] == "user":
        merged.pop()
    while merged and merged[0]["role"] == "assistant":
        merged.pop(0)
    return merged


def save_conversation(session_id: str, messages: List[Dict]):
    """Save conversation history to storage"""
    if USE_S3:
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=get_memory_path(session_id),
            Body=json.dumps(messages, indent=2),
            ContentType="application/json",
        )
    else:
        # Local file storage
        os.makedirs(MEMORY_DIR, exist_ok=True)
        file_path = os.path.join(MEMORY_DIR, get_memory_path(session_id))
        with open(file_path, "w") as f:
            json.dump(messages, f, indent=2)


def _converse_extract_text(client: Any, kwargs: Dict[str, Any]) -> str:
    response = client.converse(**kwargs)
    blocks = response["output"]["message"]["content"]
    for block in blocks:
        if isinstance(block, dict) and "text" in block:
            return block["text"]
    raise HTTPException(status_code=502, detail="Bedrock returned no text content")


def call_bedrock(conversation: List[Dict], user_message: str) -> str:
    """Call AWS Bedrock with conversation history; tries multiple regions/profiles on daily quota."""
    if _BEDROCK_STUB:
        return (
            "[BEDROCK_STUB_MODE] No AWS call. Unset BEDROCK_STUB_MODE to use Bedrock. "
            f"You said: {user_message.strip()[:400]}"
        )

    prior = _prior_messages_for_converse(conversation)
    messages = [
        {"role": m["role"], "content": [{"text": m["content"]}]} for m in prior
    ]
    messages.append(
        {
            "role": "user",
            "content": [{"text": user_message.strip()}],
        }
    )

    system_text = _bedrock_system_text()
    route_failures: List[str] = []
    routes = _bedrock_routes()
    route_started = time.monotonic()

    for route_idx, (region, model_id) in enumerate(routes):
        if time.monotonic() - route_started > _BEDROCK_ROUTE_TIME_BUDGET_S:
            route_failures.append(
                f"(stopped: {_BEDROCK_ROUTE_TIME_BUDGET_S:.0f}s route budget — API Gateway max is 30s; "
                "raise BEDROCK_ROUTE_TIME_BUDGET_S or set BEDROCK_ROUTE_CHAIN with fewer regions)"
            )
            break
        client = boto3.client(
            "bedrock-runtime",
            region_name=region,
            config=_BEDROCK_CLIENT_CFG,
        )
        converse_kwargs: Dict[str, Any] = {
            "modelId": model_id,
            "messages": messages,
            "inferenceConfig": _inference_config(model_id),
        }
        if system_text:
            converse_kwargs["system"] = [{"text": system_text}]

        last_throttle_msg = ""
        for attempt in range(_BEDROCK_CONVERSE_MAX_ATTEMPTS):
            try:
                print(f"Bedrock converse region={region} model={model_id} attempt={attempt + 1}")
                return _converse_extract_text(client, converse_kwargs)

            except ParamValidationError as e:
                print(f"Bedrock ParamValidationError {region}/{model_id}: {e}")
                raise HTTPException(
                    status_code=400,
                    detail=f"Bedrock request parameter error (model id, messages, or inferenceConfig): {e}",
                ) from e

            except (ReadTimeoutError, ConnectTimeoutError) as e:
                print(f"Bedrock timeout {region}/{model_id}: {e}")
                route_failures.append(f"{region}/{model_id}: timeout — {e}")
                break

            except ClientError as e:
                err = e.response.get("Error", {})
                error_code = err.get("Code", "")
                err_msg = err.get("Message", str(e))
                print(f"Bedrock error [{error_code}] {region}/{model_id}: {err_msg}")
                if error_code == "ValidationException":
                    raise HTTPException(status_code=400, detail=f"Bedrock validation: {err_msg}")
                if error_code == "AccessDeniedException":
                    route_failures.append(f"{region}/{model_id}: AccessDenied — {err_msg}")
                    break
                if error_code in ("ThrottlingException", "ServiceQuotaExceededException"):
                    last_throttle_msg = err_msg
                    daily = "per day" in err_msg.lower() or "tokens per day" in err_msg.lower()
                    if daily:
                        route_failures.append(f"{region}/{model_id}: daily/quota — {err_msg}")
                        break
                    if attempt < _BEDROCK_CONVERSE_MAX_ATTEMPTS - 1:
                        delay = min(2.0 * (2**attempt), 8.0)
                        print(f"Bedrock transient throttle; sleep {delay}s ({attempt + 2}/{_BEDROCK_CONVERSE_MAX_ATTEMPTS})")
                        time.sleep(delay)
                        continue
                    route_failures.append(f"{region}/{model_id}: throttled — {err_msg}")
                    break
                raise HTTPException(status_code=500, detail=f"Bedrock error: {err_msg}")

        if route_idx < len(routes) - 1:
            print(f"Trying next Bedrock route after failure on {region}/{model_id}")
            continue

    # All routes failed
    summary = " | ".join(route_failures) if route_failures else last_throttle_msg
    raise HTTPException(
        status_code=429,
        detail=(
            "Amazon Bedrock declined all configured routes: each returned a daily token (or similar) cap. "
            "That is an AWS account limit, not an app bug—wait for the rolling window to reset, or in "
            "Service Quotas request higher on-demand / token limits for Bedrock in the regions you use. "
            + _BEDROCK_QUOTA_HELP
            + f"Lambda region: {_lambda_region}. Tried: {summary}"
        ),
    )


@app.get("/")
async def root():
    return {
        "message": "AI Digital Twin API (Powered by AWS Bedrock)",
        "memory_enabled": True,
        "storage": "S3" if USE_S3 else "local",
        "ai_model": BEDROCK_MODEL_ID
    }


@app.get("/health")
async def health_check():
    return {
        "status": "healthy",
        "use_s3": USE_S3,
        "bedrock_model": BEDROCK_MODEL_ID,
        "bedrock_api_region": _bedrock_api_region,
        "bedrock_stub": _BEDROCK_STUB,
        "bedrock_routes": [f"{r[0]} → {r[1]}" for r in _bedrock_routes()],
    }


@app.get("/chat")
async def chat_get_help():
    """Browsers use GET; chat is POST-only. Avoids API Gateway 404 when opening /chat in a tab."""
    return {
        "message": "Use HTTP POST for /chat, not GET.",
        "content_type": "application/json",
        "body": {"message": "Your message here", "session_id": None},
        "session_id_note": "Omit or null for a new session; send the returned session_id on the next turn.",
    }


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest):
    try:
        # Generate session ID if not provided
        session_id = request.session_id or str(uuid.uuid4())

        # Load conversation history
        conversation = load_conversation(session_id)

        # Call Bedrock for response
        assistant_response = call_bedrock(conversation, request.message)

        # Update conversation history
        conversation.append(
            {"role": "user", "content": request.message, "timestamp": datetime.now().isoformat()}
        )
        conversation.append(
            {
                "role": "assistant",
                "content": assistant_response,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # Save conversation
        save_conversation(session_id, conversation)

        return ChatResponse(response=assistant_response, session_id=session_id)

    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in chat endpoint: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/conversation/{session_id}")
async def get_conversation(session_id: str):
    """Retrieve conversation history"""
    try:
        conversation = load_conversation(session_id)
        return {"session_id": session_id, "messages": conversation}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)