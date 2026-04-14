#!/bin/bash
set -e

# Week 2 Day 4 — Mac/Linux full deploy (Lambda + Terraform + static frontend to S3).
# Prerequisites: Docker (running), Terraform, AWS CLI (aws configure), Node/npm, uv.
# Usage: ./scripts/deploy.sh [dev|test|prod] [project_name]

ENVIRONMENT=${1:-dev}
PROJECT_NAME=${2:-twin}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "❌ Missing command: $1 (install it and retry; Day 4 uses Homebrew for Terraform.)"
    exit 1
  fi
}

echo "🚀 Day 4 deploy: ${PROJECT_NAME} → ${ENVIRONMENT}"

require_cmd docker
require_cmd terraform
require_cmd aws
require_cmd node
require_cmd npm
require_cmd uv

if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker is not running. Start Docker Desktop, then run this script again."
  exit 1
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPTS_DIR/.."

# Optional: repo-root .env with OPENAI_API_KEY (never commit .env).
# NOTE: Terraform loads terraform.tfvars AFTER TF_VAR_*, so pinned llm_provider in tfvars would ignore TF_VAR.
# We pass -var for LLM/OpenAI at apply time when a key is present (highest precedence).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
# Strip Windows CRLF from sourced values
OPENAI_API_KEY="${OPENAI_API_KEY//$'\r'/}"
LLM_PROVIDER="${LLM_PROVIDER//$'\r'/}"
OPENAI_MODEL="${OPENAI_MODEL//$'\r'/}"

OPENAI_TF_ARGS=()
if [ -n "${OPENAI_API_KEY:-}" ]; then
  _lp="${LLM_PROVIDER:-openai}"
  if [ "$_lp" = "bedrock" ]; then
    echo "⚠️  OPENAI_API_KEY is set but LLM_PROVIDER=bedrock — using bedrock; unset LLM_PROVIDER or set LLM_PROVIDER=openai for OpenAI."
  else
    _om="${OPENAI_MODEL:-gpt-4o-mini}"
    OPENAI_TF_ARGS=(
      -var="llm_provider=${_lp}"
      -var="openai_api_key=${OPENAI_API_KEY}"
      -var="openai_model=${_om}"
    )
    echo "🤖 Terraform will set Lambda LLM to ${_lp} (model ${_om}) for this apply."
  fi
fi

echo "📦 Building Lambda package (Docker + Lambda Python 3.12 image)..."
(cd backend && uv run deploy.py)

cd terraform

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-terraform-backend.sh"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="$(terraform_state_backend_region)"
echo "🔧 terraform init (S3 backend, region=${AWS_REGION})..."
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

run_terraform_apply() {
  if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
    terraform apply -var-file=prod.tfvars \
      -var="project_name=$PROJECT_NAME" \
      -var="environment=$ENVIRONMENT" \
      "${OPENAI_TF_ARGS[@]}" \
      -auto-approve
  elif [ -f "terraform.tfvars" ]; then
    terraform apply -var-file=terraform.tfvars \
      -var="project_name=$PROJECT_NAME" \
      -var="environment=$ENVIRONMENT" \
      "${OPENAI_TF_ARGS[@]}" \
      -auto-approve
  else
    terraform apply \
      -var="project_name=$PROJECT_NAME" \
      -var="environment=$ENVIRONMENT" \
      "${OPENAI_TF_ARGS[@]}" \
      -auto-approve
  fi
}

echo "🎯 Applying Terraform..."
apply_attempt=1
apply_max=3
apply_log=$(mktemp "${TMPDIR:-/tmp}/twin-tf-apply.XXXXXX")
trap 'rm -f "$apply_log"' EXIT
while [ "$apply_attempt" -le "$apply_max" ]; do
  set +e
  run_terraform_apply >"$apply_log" 2>&1
  apply_rc=$?
  set -e
  if [ "$apply_rc" -eq 0 ]; then
    cat "$apply_log"
    break
  fi
  cat "$apply_log"
  if grep -q 'Error acquiring the state lock' "$apply_log"; then
    echo ""
    echo "❌ Terraform remote state is locked (DynamoDB). Another run may hold the lock, or a past run left it stale."
    echo "   Unlock from a machine with AWS access: cd terraform && terraform workspace select ${ENVIRONMENT} && terraform force-unlock <Lock ID from the log above>"
    exit 1
  fi
  if [ "$apply_attempt" -eq "$apply_max" ]; then
    echo "❌ terraform apply failed after ${apply_max} attempts."
    exit 1
  fi
  echo "⚠️  Apply failed (transient AWS/network). Retrying in 20s (${apply_attempt}/${apply_max})..."
  sleep 20
  apply_attempt=$((apply_attempt + 1))
done

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

cd ../frontend

echo "📝 Writing .env.production (NEXT_PUBLIC_API_URL for static export)..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

CF_URL=$(terraform -chdir=terraform output -raw cloudfront_url)

echo ""
echo "✅ Day 4 deploy complete."
echo "🌐 Open in browser: $CF_URL"
echo "📡 API root check: $API_URL"
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain: $CUSTOM_URL"
fi
terraform -chdir=terraform output deployment_summary 2>/dev/null || true
echo ""
echo "Next (Day 4 Part 5): test chat on the CloudFront URL. Destroy is Part 7 — run only when you are finished."
