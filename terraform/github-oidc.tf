# Day 5 Part 4 — GitHub Actions OIDC (set github_repository in terraform.tfvars)
# Managed only in workspace "default" so dev/test/prod applies never try to recreate the account-wide OIDC provider (409).

variable "github_repository" {
  description = "GitHub repository in format 'owner/repo'"
  type        = string
}

locals {
  manage_github_oidc = terraform.workspace == "default"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = local.manage_github_oidc ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    "1b511abead59c6ce207077c0bf0e0043b1382612"
  ]
}

resource "aws_iam_role" "github_actions" {
  count = local.manage_github_oidc ? 1 : 0
  name  = "github-actions-twin-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github[0].arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_repository}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name        = "GitHub Actions Deploy Role"
    Repository  = var.github_repository
    ManagedBy   = "terraform"
  }
}

resource "aws_iam_role_policy_attachment" "github_lambda" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_s3" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_apigateway" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_cloudfront" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_iam_read" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/IAMReadOnlyAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_bedrock" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_dynamodb" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_acm" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy_attachment" "github_route53" {
  count      = local.manage_github_oidc ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
  role       = aws_iam_role.github_actions[0].name
}

resource "aws_iam_role_policy" "github_additional" {
  count = local.manage_github_oidc ? 1 : 0
  name  = "github-actions-additional"
  role  = aws_iam_role.github_actions[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:GetRole",
          "iam:GetRolePolicy",
          "iam:ListRolePolicies",
          "iam:ListAttachedRolePolicies",
          "iam:UpdateAssumeRolePolicy",
          "iam:PassRole",
          "iam:TagRole",
          "iam:UntagRole",
          "iam:ListInstanceProfilesForRole",
          "sts:GetCallerIdentity"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "Assume-role ARN for GitHub Actions (only populated in the default Terraform workspace)."
  value       = try(aws_iam_role.github_actions[0].arn, "")
}
