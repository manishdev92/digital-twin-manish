# Data source to get current AWS account ID
data "aws_caller_identity" "current" {}

locals {
  # App stack (S3, Lambda, API GW, CloudFront) only in dev/test/prod. Workspace "default" holds GitHub OIDC only (Day 5).
  deploy_app = contains(["dev", "test", "prod"], terraform.workspace)

  aliases = var.use_custom_domain && var.root_domain != "" ? [
    var.root_domain,
    "www.${var.root_domain}"
  ] : []

  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # API Gateway HTTP API Lambda integrations are limited to 30000 ms. Larger Lambda timeouts cannot return a response to the client.
  lambda_timeout_capped = min(var.lambda_timeout, 30)

  use_custom_domain_stack = local.deploy_app && var.use_custom_domain
}

# S3 bucket for conversation memory
resource "aws_s3_bucket" "memory" {
  count  = local.deploy_app ? 1 : 0
  bucket = "${local.name_prefix}-memory-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "memory" {
  count  = local.deploy_app ? 1 : 0
  bucket = aws_s3_bucket.memory[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "memory" {
  count  = local.deploy_app ? 1 : 0
  bucket = aws_s3_bucket.memory[0].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# S3 bucket for frontend static website
resource "aws_s3_bucket" "frontend" {
  count  = local.deploy_app ? 1 : 0
  bucket = "${local.name_prefix}-frontend-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  count  = local.deploy_app ? 1 : 0
  bucket = aws_s3_bucket.frontend[0].id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  count  = local.deploy_app ? 1 : 0
  bucket = aws_s3_bucket.frontend[0].id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "404.html"
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  count  = local.deploy_app ? 1 : 0
  bucket = aws_s3_bucket.frontend[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend[0].arn}/*"
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  count = local.deploy_app ? 1 : 0
  name  = "${local.name_prefix}-lambda-role"
  tags  = local.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count      = local.deploy_app ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  role       = aws_iam_role.lambda_role[0].name
}

resource "aws_iam_role_policy_attachment" "lambda_bedrock" {
  count      = local.deploy_app ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.lambda_role[0].name
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  count      = local.deploy_app ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.lambda_role[0].name
}

# Lambda function
resource "aws_lambda_function" "api" {
  count            = local.deploy_app ? 1 : 0
  filename         = "${path.module}/../backend/lambda-deployment.zip"
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.lambda_role[0].arn
  handler          = "lambda_handler.handler"
  source_code_hash = filebase64sha256("${path.module}/../backend/lambda-deployment.zip")
  runtime          = "python3.12"
  architectures    = ["x86_64"]
  timeout          = local.lambda_timeout_capped
  tags             = local.common_tags

  environment {
    variables = merge(
      {
        CORS_ORIGINS     = var.use_custom_domain ? "https://${var.root_domain},https://www.${var.root_domain}" : "https://${aws_cloudfront_distribution.main[0].domain_name}"
        S3_BUCKET        = aws_s3_bucket.memory[0].id
        USE_S3           = "true"
        BEDROCK_MODEL_ID = var.bedrock_model_id
        LLM_PROVIDER     = var.llm_provider
      },
      var.bedrock_runtime_region != "" ? { BEDROCK_RUNTIME_REGION = var.bedrock_runtime_region } : {},
      var.llm_provider == "openai" ? merge(
        { OPENAI_MODEL = var.openai_model },
        var.openai_api_key != "" ? { OPENAI_API_KEY = var.openai_api_key } : {}
      ) : {}
    )
  }

  # Ensure Lambda waits for the distribution to exist
  depends_on = [aws_cloudfront_distribution.main]
}

# API Gateway HTTP API
resource "aws_apigatewayv2_api" "main" {
  count         = local.deploy_app ? 1 : 0
  name          = "${local.name_prefix}-api-gateway"
  protocol_type = "HTTP"
  tags          = local.common_tags

  cors_configuration {
    allow_credentials = false
    allow_headers     = ["*"]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_origins     = ["*"]
    max_age           = 300
  }
}

resource "aws_apigatewayv2_stage" "default" {
  count       = local.deploy_app ? 1 : 0
  api_id      = aws_apigatewayv2_api.main[0].id
  name        = "$default"
  auto_deploy = true
  tags        = local.common_tags

  default_route_settings {
    throttling_burst_limit = var.api_throttle_burst_limit
    throttling_rate_limit  = var.api_throttle_rate_limit
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  count                  = local.deploy_app ? 1 : 0
  api_id                 = aws_apigatewayv2_api.main[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api[0].invoke_arn
  # Must match local.lambda_timeout_capped * 1000 (max 30000 for HTTP API + Lambda).
  timeout_milliseconds = local.lambda_timeout_capped * 1000
}

# API Gateway Routes
resource "aws_apigatewayv2_route" "get_root" {
  count     = local.deploy_app ? 1 : 0
  api_id    = aws_apigatewayv2_api.main[0].id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
}

resource "aws_apigatewayv2_route" "post_chat" {
  count     = local.deploy_app ? 1 : 0
  api_id    = aws_apigatewayv2_api.main[0].id
  route_key = "POST /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
}

resource "aws_apigatewayv2_route" "get_chat" {
  count     = local.deploy_app ? 1 : 0
  api_id    = aws_apigatewayv2_api.main[0].id
  route_key = "GET /chat"
  target    = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
}

resource "aws_apigatewayv2_route" "get_health" {
  count     = local.deploy_app ? 1 : 0
  api_id    = aws_apigatewayv2_api.main[0].id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda[0].id}"
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gw" {
  count         = local.deploy_app ? 1 : 0
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main[0].execution_arn}/*/*"
}

# CloudFront distribution
resource "aws_cloudfront_distribution" "main" {
  count   = local.deploy_app ? 1 : 0
  aliases = local.aliases

  viewer_certificate {
    acm_certificate_arn            = var.use_custom_domain ? aws_acm_certificate.site[0].arn : null
    cloudfront_default_certificate = var.use_custom_domain ? false : true
    ssl_support_method             = var.use_custom_domain ? "sni-only" : null
    minimum_protocol_version       = "TLSv1.2_2021"
  }

  origin {
    domain_name = aws_s3_bucket_website_configuration.frontend[0].website_endpoint
    origin_id   = "S3-${aws_s3_bucket.frontend[0].id}"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  tags                = local.common_tags
  # Avoid holding one Terraform/AWS signing session through long CloudFront propagation (can hit SignatureExpired on slow networks or skewed laptop clocks).
  wait_for_deployment = false

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3-${aws_s3_bucket.frontend[0].id}"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }
}

# Optional: Custom domain configuration (only created when use_custom_domain = true)
data "aws_route53_zone" "root" {
  count        = local.use_custom_domain_stack ? 1 : 0
  name         = var.root_domain
  private_zone = false
}

resource "aws_acm_certificate" "site" {
  count                     = local.use_custom_domain_stack ? 1 : 0
  provider                  = aws.us_east_1
  domain_name               = var.root_domain
  subject_alternative_names = ["www.${var.root_domain}"]
  validation_method         = "DNS"
  lifecycle { create_before_destroy = true }
  tags                      = local.common_tags
}

resource "aws_route53_record" "site_validation" {
  for_each = local.use_custom_domain_stack ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options :
    dvo.domain_name => dvo
  } : {}

  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  ttl     = 300
  records = [each.value.resource_record_value]
}

resource "aws_acm_certificate_validation" "site" {
  count             = local.use_custom_domain_stack ? 1 : 0
  provider          = aws.us_east_1
  certificate_arn   = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [
    for r in aws_route53_record.site_validation : r.fqdn
  ]
}

resource "aws_route53_record" "alias_root" {
  count   = local.use_custom_domain_stack ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_root_ipv6" {
  count   = local.use_custom_domain_stack ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = var.root_domain
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_www" {
  count   = local.use_custom_domain_stack ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "alias_www_ipv6" {
  count   = local.use_custom_domain_stack ? 1 : 0
  zone_id = data.aws_route53_zone.root[0].zone_id
  name    = "www.${var.root_domain}"
  type    = "AAAA"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}
