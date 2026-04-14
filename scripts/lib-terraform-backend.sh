# Sourced by deploy.sh / destroy.sh / bootstrap-terraform-backend.sh
# Resolves AWS region for the Terraform S3 state bucket (must match bucket + DynamoDB lock table region).

terraform_state_backend_region() {
  local account
  account=$(aws sts get-caller-identity --query Account --output text)
  local bucket="twin-terraform-state-${account}"
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    local loc
    loc=$(aws s3api get-bucket-location --bucket "$bucket" --query LocationConstraint --output text 2>/dev/null || echo "")
    if [ -z "$loc" ] || [ "$loc" = "None" ] || [ "$loc" = "null" ]; then
      printf '%s\n' "us-east-1"
    else
      printf '%s\n' "$loc"
    fi
    return
  fi
  local r="${DEFAULT_AWS_REGION:-${AWS_REGION:-}}"
  if [ -z "$r" ]; then
    r=$(aws configure get region 2>/dev/null || true)
  fi
  printf '%s\n' "${r:-ap-south-1}"
}
