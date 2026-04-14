#!/bin/bash
set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
cd terraform
terraform init -input=false

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Region must match the provider (from AWS CLI / env); used for DNS preflight
DEPLOY_AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [ -z "$DEPLOY_AWS_REGION" ]; then
  DEPLOY_AWS_REGION=$(aws configure get region 2>/dev/null || true)
fi
if [ -z "$DEPLOY_AWS_REGION" ]; then
  DEPLOY_AWS_REGION="ap-south-1"
fi
GW_HOST="apigateway.${DEPLOY_AWS_REGION}.amazonaws.com"
echo "🌐 Verifying DNS for ${GW_HOST}..."
if ! python3 -c "import socket; socket.getaddrinfo('${GW_HOST}', 443, type=socket.SOCK_STREAM)" 2>/dev/null; then
  echo "❌ Cannot resolve ${GW_HOST}. This usually means DNS or connectivity failed (Wi‑Fi/VPN/captive portal)."
  echo "   Try: reconnect the network, switch DNS (e.g. 8.8.8.8), then run the deploy script again."
  echo "   If Terraform partially applied, rerun the same command; it will finish remaining resources."
  exit 1
fi

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -auto-approve)
fi

apply_attempt=1
apply_max=3
while [ "$apply_attempt" -le "$apply_max" ]; do
  echo "🎯 Applying Terraform (attempt ${apply_attempt}/${apply_max})..."
  if "${TF_APPLY_CMD[@]}"; then
    break
  fi
  if [ "$apply_attempt" -eq "$apply_max" ]; then
    echo "❌ Terraform apply failed after ${apply_max} attempts."
    exit 1
  fi
  echo "⚠️  Terraform apply failed (often transient DNS/network). Retrying in 25s..."
  sleep 25
  apply_attempt=$((apply_attempt + 1))
done

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
echo "📝 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\n✅ Deployment complete!"
echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
echo "📋 deployment_summary (frontend + API):"
terraform -chdir=terraform output deployment_summary
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"