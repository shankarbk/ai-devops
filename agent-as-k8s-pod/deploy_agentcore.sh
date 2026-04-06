#!/bin/bash
# Full deployment pipeline: build → ECR → AgentCore

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="devops-agent"
IMAGE_TAG="latest"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO_NAME}"

# 1. Create ECR repository (skip if exists)
aws ecr create-repository \
  --repository-name $REPO_NAME \
  --region $REGION \
  --image-scanning-configuration scanOnPush=true 2>/dev/null || true

# 2. Authenticate Docker to ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin \
  ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

# 3. Build image (for arm64/amd64 compatibility)
docker buildx build \
  --platform linux/amd64 \
  --tag ${ECR_URI}:${IMAGE_TAG} \
  --push \
  .

echo "Image pushed: ${ECR_URI}:${IMAGE_TAG}"