#!/bin/bash
# Bootstrap script: uploads nested templates to S3 then creates/updates the root stack.
# Run this once before GitSync takes over, or to manually update the stack.
# Usage: ./deploy.sh <aws-region> <account-id> <github-org> <db-password>

set -euo pipefail

REGION=${1:-us-east-1}
ACCOUNT_ID=${2:?'account-id required'}
GITHUB_ORG=${3:?'github-org required'}
DB_PASSWORD=${4:?'db-password required'}

PROJECT=photo-uploader
TEMPLATES_BUCKET="${PROJECT}-cfn-${ACCOUNT_ID}"
STACK_NAME="${PROJECT}-stack"

echo ">>> Creating templates bucket if needed..."
aws s3api head-bucket --bucket "$TEMPLATES_BUCKET" 2>/dev/null || \
  aws s3 mb "s3://${TEMPLATES_BUCKET}" --region "$REGION"

aws s3api put-bucket-versioning \
  --bucket "$TEMPLATES_BUCKET" \
  --versioning-configuration Status=Enabled

echo ">>> Uploading templates..."
aws s3 sync templates/ "s3://${TEMPLATES_BUCKET}/templates/" --region "$REGION"

echo ">>> Deploying root stack..."
aws cloudformation deploy \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --template-file templates/main.yml \
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --parameter-overrides \
    ProjectName="$PROJECT" \
    Environment=prod \
    GitHubOrg="$GITHUB_ORG" \
    GitHubRepo="$PROJECT" \
    ContainerImage="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${PROJECT}:latest" \
    DBPassword="$DB_PASSWORD" \
    TemplatesBucketName="$TEMPLATES_BUCKET" \
  --tags Project="$PROJECT" Environment=prod ManagedBy=CloudFormation

echo ">>> Stack outputs:"
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table
