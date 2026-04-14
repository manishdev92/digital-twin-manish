locals {
  out_deploy_app = contains(["dev", "test", "prod"], terraform.workspace)
}

output "api_gateway_url" {
  description = "URL of the API Gateway"
  value       = local.out_deploy_app ? aws_apigatewayv2_api.main[0].api_endpoint : null
}

output "cloudfront_url" {
  description = "URL of the CloudFront distribution"
  value       = local.out_deploy_app ? "https://${aws_cloudfront_distribution.main[0].domain_name}" : null
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation and support)"
  value       = local.out_deploy_app ? aws_cloudfront_distribution.main[0].id : null
}

output "deployment_summary" {
  description = "Human-readable map of main URLs (same values as individual outputs)"
  value = local.out_deploy_app ? {
    frontend = "https://${aws_cloudfront_distribution.main[0].domain_name}"
    api      = aws_apigatewayv2_api.main[0].api_endpoint
  } : null
}

output "s3_frontend_bucket" {
  description = "Name of the S3 bucket for frontend"
  value       = local.out_deploy_app ? aws_s3_bucket.frontend[0].id : null
}

output "s3_memory_bucket" {
  description = "Name of the S3 bucket for memory storage"
  value       = local.out_deploy_app ? aws_s3_bucket.memory[0].id : null
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = local.out_deploy_app ? aws_lambda_function.api[0].function_name : null
}

output "custom_domain_url" {
  description = "Root URL of the production site"
  value       = var.use_custom_domain ? "https://${var.root_domain}" : ""
}
