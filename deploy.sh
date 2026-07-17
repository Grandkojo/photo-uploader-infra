#!/bin/bash
# Bootstrap script: uploads nested templates to S3, deploys in two phases.
#
# Phase 1: Creates all stacks EXCEPT CodePipeline (ECR repo is empty at this point).
# Seed:    Pushes a placeholder image to ECR so CodePipeline can validate the source.
# Phase 2: Creates CodePipelineStack now that the ECR image exists.
#
# After this completes, connect GitSync in the AWS Console → CloudFormation → Stacks.
# Point it to deployment-file.yml (which has DeployPipeline=true).
# All future pushes to deployment-file.yml then auto-trigger stack updates.
#
# Prerequisites:
#   aws ssm put-parameter \
#     --name /photo-uploader/db/password \
#     --value "YourStrongPassword123!" \
#     --type SecureString \
#     --region <REGION>
#
#   docker must be installed and running (used to push the ECR seed image)
#
# Usage: ./deploy.sh <aws-region> <account-id> <github-org> [aws-profile]
# Example: ./deploy.sh eu-west-1 843632604592 Grandkojo ernestessien

set -euo pipefail

REGION=${1:?'aws-region required (e.g. eu-west-1)'}
ACCOUNT_ID=${2:?'account-id required (12-digit AWS account ID)'}
GITHUB_ORG=${3:?'github-org required (e.g. Grandkojo)'}
PROFILE=${4:-}

# Build a reusable --profile flag (empty string if no profile given)
PROFILE_FLAG=""
if [[ -n "$PROFILE" ]]; then
  PROFILE_FLAG="--profile $PROFILE"
fi

PROJECT=photo-uploader
TEMPLATES_BUCKET="${PROJECT}-cfn-${ACCOUNT_ID}"
STACK_NAME="${PROJECT}-stack"
SSM_DB_PASSWORD_PATH="/photo-uploader/db/password"
SEED_IMAGE="public.ecr.aws/docker/library/node:20-alpine"

echo ">>> Verifying SSM password parameter exists..."
# shellcheck disable=SC2086
aws ssm get-parameter \
  --name "$SSM_DB_PASSWORD_PATH" \
  --with-decryption \
  --region "$REGION" \
  $PROFILE_FLAG \
  --query 'Parameter.Name' \
  --output text > /dev/null || {
    echo "ERROR: SSM parameter '$SSM_DB_PASSWORD_PATH' not found."
    echo "Create it first:"
    echo "  aws ssm put-parameter --name $SSM_DB_PASSWORD_PATH \\"
    echo "    --value 'YourStrongPassword123!' --type SecureString --region $REGION"
    exit 1
  }

echo ">>> Creating templates bucket if needed..."
# shellcheck disable=SC2086
aws s3api head-bucket --bucket "$TEMPLATES_BUCKET" --region "$REGION" $PROFILE_FLAG 2>/dev/null || \
  aws s3 mb "s3://${TEMPLATES_BUCKET}" --region "$REGION" $PROFILE_FLAG

# shellcheck disable=SC2086
aws s3api put-bucket-versioning \
  --bucket "$TEMPLATES_BUCKET" \
  --versioning-configuration Status=Enabled \
  --region "$REGION" \
  $PROFILE_FLAG

echo ">>> Uploading nested templates to S3..."
# shellcheck disable=SC2086
aws s3 sync templates/ "s3://${TEMPLATES_BUCKET}/templates/" \
  --region "$REGION" \
  --delete \
  $PROFILE_FLAG

# ── PHASE 1: deploy everything except CodePipeline ───────────────────────────
echo ""
echo ">>> [Phase 1] Deploying stacks (VPC, S3, ECR, RDS, ECS) — skipping CodePipeline..."
# shellcheck disable=SC2086
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
    ContainerImage="$SEED_IMAGE" \
    TemplatesBucketName="$TEMPLATES_BUCKET" \
    DeployPipeline="false" \
  --tags Project="$PROJECT" Environment=prod ManagedBy=CloudFormation \
  $PROFILE_FLAG

echo ""
echo ">>> [Phase 1] Complete. Fetching ECR repository URI..."
# shellcheck disable=SC2086
ECR_URI=$(aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  $PROFILE_FLAG \
  --query 'Stacks[0].Outputs[?OutputKey==`ECRRepositoryUri`].OutputValue' \
  --output text)

echo "    ECR URI: $ECR_URI"

# ── SEED: push placeholder image to ECR ──────────────────────────────────────
echo ""
echo ">>> [Seed] Authenticating with ECR and pushing placeholder image..."
# shellcheck disable=SC2086
aws ecr get-login-password --region "$REGION" $PROFILE_FLAG \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "    Pulling $SEED_IMAGE..."
docker pull --platform linux/amd64 "$SEED_IMAGE"

echo "    Tagging and pushing to ECR as ${ECR_URI}:latest..."
docker tag "$SEED_IMAGE" "${ECR_URI}:latest"
docker push "${ECR_URI}:latest"

echo "    ECR seed image pushed successfully."

# ── PHASE 2: deploy CodePipeline now that ECR has an image ───────────────────
echo ""
echo ">>> [Phase 2] Deploying CodePipeline (ECR image now exists)..."
# shellcheck disable=SC2086
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
    ContainerImage="$SEED_IMAGE" \
    TemplatesBucketName="$TEMPLATES_BUCKET" \
    DeployPipeline="true" \
  --tags Project="$PROJECT" Environment=prod ManagedBy=CloudFormation \
  $PROFILE_FLAG

echo ""
echo ">>> Stack outputs:"
# shellcheck disable=SC2086
aws cloudformation describe-stacks \
  --region "$REGION" \
  --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs' \
  --output table \
  $PROFILE_FLAG

echo ""
echo ">>> Bootstrap complete."
echo "    Next steps:"
echo "    1. Set up GitSync: AWS Console → CloudFormation → Stacks → $STACK_NAME"
echo "       Point it to deployment-file.yml in your infra repo."
echo "    2. Push your app code to GitHub → GitHub Actions builds and pushes the real image."
echo "    3. CodePipeline auto-triggers on the ECR push and does a blue/green deploy."
