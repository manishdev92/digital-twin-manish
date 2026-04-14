# Day 5 — S3 remote state (bucket must exist first; run scripts/bootstrap-terraform-backend.sh once per account)
terraform {
  backend "s3" {}
}
