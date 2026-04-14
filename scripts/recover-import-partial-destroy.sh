#!/bin/bash
set -e

# Re-link an orphaned Lambda execution IAM role into Terraform state (partial destroy / lost state).
# Usage from repo root: ./scripts/recover-import-partial-destroy.sh dev [project_name]

ENVIRONMENT=${1:?usage: $0 <dev|test|prod> [project_name]}
PROJECT_NAME=${2:-twin}

PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
ROLE_NAME="${PREFIX}-lambda-role"

cd "$(dirname "$0")/../terraform"

terraform init -input=false
terraform workspace select "$ENVIRONMENT"

import_if_missing() {
  local addr=$1
  local id=$2
  if terraform state show "$addr" >/dev/null 2>&1; then
    echo "  (skip) already in state: $addr"
    return 0
  fi
  echo "  importing $addr <- $id"
  terraform import "$addr" "$id"
}

if ! aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "No AWS role $ROLE_NAME — nothing to import. Run ./scripts/deploy.sh $ENVIRONMENT $PROJECT_NAME"
  exit 0
fi

echo "Recovering Lambda IAM role ${ROLE_NAME}..."
import_if_missing aws_iam_role.lambda_role "$ROLE_NAME"
import_if_missing aws_iam_role_policy_attachment.lambda_basic \
  "${ROLE_NAME}/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
import_if_missing aws_iam_role_policy_attachment.lambda_bedrock \
  "${ROLE_NAME}/arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
import_if_missing aws_iam_role_policy_attachment.lambda_s3 \
  "${ROLE_NAME}/arn:aws:iam::aws:policy/AmazonS3FullAccess"

echo ""
echo "Done. Run: ./scripts/deploy.sh $ENVIRONMENT $PROJECT_NAME"
