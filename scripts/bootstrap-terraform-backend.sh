#!/bin/bash
set -e
# Day 5 Part 3 — run ONCE per AWS account from repo root: ./scripts/bootstrap-terraform-backend.sh
# Creates S3 + DynamoDB for Terraform state (if missing), detaches them from this root state, then uses backend.tf + deploy.sh.

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
cd "$ROOT/terraform"

if [ ! -f backend.tf ] && [ -f backend.tf.bak ]; then
  echo "Recovering backend.tf from backend.tf.bak (previous run may have failed mid-bootstrap)."
  mv backend.tf.bak backend.tf
fi

if [ ! -f backend.tf ]; then
  echo "backend.tf missing — abort."
  exit 1
fi

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="twin-terraform-state-${ACCOUNT}"
BUCKET_EXISTS=0
if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
  BUCKET_EXISTS=1
fi

echo "Temporarily disabling S3 backend block so we can create the state bucket with local state..."
mv backend.tf backend.tf.bak

terraform init -input=false
terraform workspace select default

if [ "$BUCKET_EXISTS" -eq 1 ]; then
  echo "State bucket ${STATE_BUCKET} already exists — skipping backend resource apply and state rm."
  rm -f backend-setup.tf
else
  if [ ! -f backend-setup.tf ]; then
    if [ ! -f backend-setup.tf.example ]; then
      echo "backend-setup.tf.example missing — cannot create state bucket. Abort."
      mv backend.tf.bak backend.tf
      exit 1
    fi
    echo "Creating backend-setup.tf from backend-setup.tf.example"
    cp backend-setup.tf.example backend-setup.tf
  fi
  echo "Applying backend storage (S3 + DynamoDB)..."
  terraform apply -auto-approve \
    -target=aws_s3_bucket.terraform_state \
    -target=aws_s3_bucket_versioning.terraform_state \
    -target=aws_s3_bucket_server_side_encryption_configuration.terraform_state \
    -target=aws_s3_bucket_public_access_block.terraform_state \
    -target=aws_dynamodb_table.terraform_locks

  echo "Removing backend resources from Terraform state (AWS objects stay; avoids destroy on next apply)..."
  for addr in \
    aws_s3_bucket_versioning.terraform_state \
    aws_s3_bucket_server_side_encryption_configuration.terraform_state \
    aws_s3_bucket_public_access_block.terraform_state \
    aws_s3_bucket.terraform_state \
    aws_dynamodb_table.terraform_locks
   do
    terraform state rm "$addr" 2>/dev/null || true
   done

  rm -f backend-setup.tf
  echo "Removed backend-setup.tf from disk."
fi

mv backend.tf.bak backend.tf

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-terraform-backend.sh"
REGION="$(terraform_state_backend_region)"
echo "Re-init with S3 backend (migrate local state if any), region=${REGION}..."
printf 'yes\n' | terraform init -input=false -migrate-state \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

echo ""
echo "Bootstrap done. Use ./scripts/deploy.sh dev — S3 backend key is terraform.tfstate; workspaces use env:/<workspace>/ prefixes in the bucket."
