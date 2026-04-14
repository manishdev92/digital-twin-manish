variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Environment name (dev, test, prod)"
  type        = string
  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, prod."
  }
}

variable "bedrock_model_id" {
  description = "Bedrock inference profile ID (e.g. global.amazon.nova-2-lite-v1:0 per course FAQ Q42; regional us./eu./apac.* prefixes must match bedrock_runtime_region)"
  type        = string
  default     = "global.amazon.nova-2-lite-v1:0"
}

variable "bedrock_runtime_region" {
  description = "Region for the Bedrock Runtime API only (empty = same as Lambda). For global.* profiles, use a documented source region or leave empty when Lambda is in one."
  type        = string
  default     = ""
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds (Terraform caps at 30s: API Gateway HTTP API + Lambda integration max is 30s)."
  type        = number
  default     = 60
}

variable "api_throttle_burst_limit" {
  description = "API Gateway throttle burst limit"
  type        = number
  default     = 10
}

variable "api_throttle_rate_limit" {
  description = "API Gateway throttle rate limit"
  type        = number
  default     = 5
}

variable "use_custom_domain" {
  description = "Attach a custom domain to CloudFront"
  type        = bool
  default     = false
}

variable "root_domain" {
  description = "Apex domain name, e.g. mydomain.com"
  type        = string
  default     = ""
}

variable "llm_provider" {
  description = "LLM backend: bedrock (course default) or openai"
  type        = string
  default     = "bedrock"

  validation {
    condition     = contains(["bedrock", "openai"], var.llm_provider)
    error_message = "llm_provider must be bedrock or openai."
  }
}

variable "openai_api_key" {
  description = "OpenAI API key for Lambda when llm_provider=openai (use TF_VAR_openai_api_key or .env OPENAI_API_KEY via deploy.sh; never commit)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_model" {
  description = "OpenAI chat model id when llm_provider=openai"
  type        = string
  default     = "gpt-4o-mini"
}