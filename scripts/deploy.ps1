# Week 2 Day 4 Part 4 — Windows (local PowerShell; CI/CD is Day 5)
param(
    [string]$Environment = "dev",
    [string]$ProjectName = "twin"
)

$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
uv run deploy.py
Set-Location ..

Set-Location terraform
terraform init -input=false

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
}
else {
    terraform workspace select $Environment
}

Write-Host "Applying Terraform..." -ForegroundColor Yellow
if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
    terraform apply -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}
elseif (Test-Path "terraform.tfvars") {
    terraform apply -var-file="terraform.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}
else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

$ApiUrl = terraform output -raw api_gateway_url
$FrontendBucket = terraform output -raw s3_frontend_bucket
try { $CustomUrl = terraform output -raw custom_domain_url } catch { $CustomUrl = "" }

Set-Location ..\frontend
Write-Host "Setting API URL for production..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File .env.production -Encoding utf8

npm install
npm run build
aws s3 sync .\out "s3://$FrontendBucket/" --delete
Set-Location ..

$CfUrl = terraform -chdir=terraform output -raw cloudfront_url
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CfUrl" -ForegroundColor Cyan
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl" -ForegroundColor Cyan
}
Write-Host "API Gateway    : $ApiUrl" -ForegroundColor Cyan
