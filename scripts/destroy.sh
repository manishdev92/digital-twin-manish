#!/bin/bash
set -e

# Week 2 Day 4 Part 7 — Mac/Linux. CloudFront teardown can take 15+ minutes.
# SignatureExpired on long destroys: sync Mac clock, refresh AWS credentials, re-run destroy.
# If you deployed OpenAI via .env, source the same .env here so destroy gets matching -var (same as deploy.sh).

if [ $# -eq 0 ]; then
  echo "❌ Error: Environment parameter is required"
  echo "Usage: $0 <environment> [project_name]"
  echo "Example: $0 dev"
  echo "Available environments: dev, test, prod"
  exit 1
fi

ENVIRONMENT=$1
PROJECT_NAME=${2:-twin}

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
cd "$ROOT"

# Match deploy.sh: OpenAI vars were applied with CLI -var; pass the same on destroy if .env has a key.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
OPENAI_API_KEY="${OPENAI_API_KEY//$'\r'/}"
LLM_PROVIDER="${LLM_PROVIDER//$'\r'/}"
OPENAI_MODEL="${OPENAI_MODEL//$'\r'/}"

OPENAI_TF_ARGS=()
if [ -n "${OPENAI_API_KEY:-}" ]; then
  _lp="${LLM_PROVIDER:-openai}"
  if [ "$_lp" != "bedrock" ]; then
    _om="${OPENAI_MODEL:-gpt-4o-mini}"
    OPENAI_TF_ARGS=(
      -var="llm_provider=${_lp}"
      -var="openai_api_key=${OPENAI_API_KEY}"
      -var="openai_model=${_om}"
    )
    echo "🤖 Destroy will use same LLM/OpenAI -var flags as deploy (from .env)."
  fi
fi

echo "🗑️ Preparing to destroy ${PROJECT_NAME}-${ENVIRONMENT} infrastructure..."

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
  echo "❌ Error: Workspace '$ENVIRONMENT' does not exist"
  echo "Available workspaces:"
  terraform workspace list
  exit 1
fi

terraform workspace select "$ENVIRONMENT"

echo "📦 Emptying S3 buckets..."

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

FRONTEND_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-frontend-${AWS_ACCOUNT_ID}"
MEMORY_BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-memory-${AWS_ACCOUNT_ID}"

if aws s3 ls "s3://$FRONTEND_BUCKET" 2>/dev/null; then
  echo "  Emptying $FRONTEND_BUCKET..."
  aws s3 rm "s3://$FRONTEND_BUCKET" --recursive
else
  echo "  Frontend bucket not found or already empty"
fi

if aws s3 ls "s3://$MEMORY_BUCKET" 2>/dev/null; then
  echo "  Emptying $MEMORY_BUCKET..."
  aws s3 rm "s3://$MEMORY_BUCKET" --recursive
else
  echo "  Memory bucket not found or already empty"
fi

# Terraform may still read the Lambda zip path during destroy refresh.
if [ ! -f "../backend/lambda-deployment.zip" ]; then
  echo "📦 Creating placeholder lambda-deployment.zip for destroy..."
  (cd ../backend && echo placeholder >_destroy.txt && zip -q lambda-deployment.zip _destroy.txt && rm -f _destroy.txt)
fi

echo "🔥 Running terraform destroy..."

if [ "$ENVIRONMENT" = "prod" ] && [ -f "prod.tfvars" ]; then
  terraform destroy -var-file=prod.tfvars \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    "${OPENAI_TF_ARGS[@]}" \
    -auto-approve
elif [ -f "terraform.tfvars" ]; then
  terraform destroy -var-file=terraform.tfvars \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    "${OPENAI_TF_ARGS[@]}" \
    -auto-approve
else
  terraform destroy \
    -var="project_name=$PROJECT_NAME" \
    -var="environment=$ENVIRONMENT" \
    "${OPENAI_TF_ARGS[@]}" \
    -auto-approve
fi

echo "✅ Infrastructure for ${ENVIRONMENT} has been destroyed!"
echo ""
echo "💡 To remove the workspace completely, run:"
echo "   cd terraform && terraform workspace select default"
echo "   terraform workspace delete $ENVIRONMENT"
