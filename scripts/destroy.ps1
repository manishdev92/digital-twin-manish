# Week 2 Day 4 Part 7 — Windows destroy
param(
    [Parameter(Mandatory = $true)]
    [string]$Environment,
    [string]$ProjectName = "twin"
)

$ErrorActionPreference = "Stop"

if ($Environment -notmatch '^(dev|test|prod)$') {
    Write-Host "Error: Invalid environment '$Environment'" -ForegroundColor Red
    Write-Host "Available environments: dev, test, prod" -ForegroundColor Yellow
    exit 1
}

Write-Host "Preparing to destroy $ProjectName-$Environment infrastructure..." -ForegroundColor Yellow

Set-Location (Join-Path (Split-Path $PSScriptRoot -Parent) "terraform")

terraform init -input=false

$workspaces = terraform workspace list
if (-not ($workspaces | Select-String $Environment)) {
    Write-Host "Error: Workspace '$Environment' does not exist" -ForegroundColor Red
    Write-Host "Available workspaces:" -ForegroundColor Yellow
    terraform workspace list
    exit 1
}

terraform workspace select $Environment

Write-Host "Emptying S3 buckets..." -ForegroundColor Yellow

$awsAccountId = aws sts get-caller-identity --query Account --output text
$FrontendBucket = "$ProjectName-$Environment-frontend-$awsAccountId"
$MemoryBucket = "$ProjectName-$Environment-memory-$awsAccountId"

try {
    aws s3 ls "s3://$FrontendBucket" 2>$null | Out-Null
    Write-Host "  Emptying $FrontendBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$FrontendBucket" --recursive
}
catch {
    Write-Host "  Frontend bucket not found or already empty" -ForegroundColor Gray
}

try {
    aws s3 ls "s3://$MemoryBucket" 2>$null | Out-Null
    Write-Host "  Emptying $MemoryBucket..." -ForegroundColor Gray
    aws s3 rm "s3://$MemoryBucket" --recursive
}
catch {
    Write-Host "  Memory bucket not found or already empty" -ForegroundColor Gray
}

Write-Host "Running terraform destroy..." -ForegroundColor Yellow

if ($Environment -eq "prod" -and (Test-Path "prod.tfvars")) {
    terraform destroy -var-file="prod.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}
elseif (Test-Path "terraform.tfvars") {
    terraform destroy -var-file="terraform.tfvars" -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}
else {
    terraform destroy -var="project_name=$ProjectName" -var="environment=$Environment" -auto-approve
}

Write-Host "Infrastructure for $Environment has been destroyed!" -ForegroundColor Green
Write-Host ""
Write-Host "  To remove the workspace completely, run:" -ForegroundColor Cyan
Write-Host "   terraform workspace select default" -ForegroundColor White
Write-Host "   terraform workspace delete $Environment" -ForegroundColor White
