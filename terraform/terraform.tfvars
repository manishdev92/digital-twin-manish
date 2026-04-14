# Week 2 Day 4 Step 6 — default dev values (Day 3 Bedrock Q42 below; GitHub OIDC is Day 5).
# CLI overrides: ./scripts/deploy.sh test  →  -var environment=test overrides environment here.
project_name             = "twin"
environment              = "dev"
# Day 5 GitHub OIDC — must match the repo that runs Actions (owner/repo only, no URL)
github_repository        = "manishdev92/digital-twin-manish"
# Q42 https://edwarddonner.com/faq — prefer global Nova 2 Lite (pooled quota). Empty = Bedrock client uses Lambda region.
bedrock_runtime_region   = ""
bedrock_model_id         = "global.amazon.nova-2-lite-v1:0"
# llm_provider / openai_model: use defaults in variables.tf (bedrock). deploy.sh passes -var when .env has OPENAI_API_KEY.
lambda_timeout           = 60
api_throttle_burst_limit = 10
api_throttle_rate_limit  = 5
use_custom_domain        = false
root_domain              = ""