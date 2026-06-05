#!/bin/bash
###############################################################################
# Veilborn AWS — Full Deployment Script
# 
# Usage:
#   ./deploy.sh [dev|staging|prod] [--skip-build] [--skip-infra]
#
# Requirements:
#   - AWS CLI configured (aws configure)
#   - Terraform >= 1.6 installed
#   - Docker installed and running
#   - Godot 4.3 installed at /usr/local/bin/godot (or set GODOT_BIN)
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA_DIR="$ROOT_DIR/infrastructure/terraform"
DOCKER_DIR="$ROOT_DIR/server/docker"

# ─── Arguments ────────────────────────────────────────────────────────────────
ENVIRONMENT="${1:-dev}"
SKIP_BUILD=false
SKIP_INFRA=false

for arg in "${@:2}"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=true ;;
    --skip-infra) SKIP_INFRA=true ;;
  esac
done

if [[ ! "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]]; then
  echo "ERROR: Environment must be dev, staging, or prod"
  echo "Usage: $0 [dev|staging|prod] [--skip-build] [--skip-infra]"
  exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║     Veilborn AWS Deployment — $ENVIRONMENT         "
echo "║     $(date -u '+%Y-%m-%d %H:%M:%S UTC')             "
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ─── Configuration ────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="$AWS_ACCOUNT.dkr.ecr.$AWS_REGION.amazonaws.com"
ECR_REPO="veilborn-server"
IMAGE_TAG="${ENVIRONMENT}-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"
GODOT_BIN="${GODOT_BIN:-godot}"

echo "AWS Account  : $AWS_ACCOUNT"
echo "AWS Region   : $AWS_REGION"
echo "ECR Registry : $ECR_REGISTRY"
echo "Image Tag    : $IMAGE_TAG"
echo ""

# ─── Step 1: Export Godot server binary ───────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  echo "━━━ Step 1/5: Exporting Godot Server ━━━━━━━━━━━━━━━"
  
  GAME_DIR="${GAME_DIR:-$ROOT_DIR/../../}"
  EXPORT_DIR="$ROOT_DIR/server/docker/export"
  mkdir -p "$EXPORT_DIR"
  
  if [[ ! -f "$GAME_DIR/project.godot" ]]; then
    echo "ERROR: project.godot not found at $GAME_DIR"
    echo "Set GAME_DIR to the path of your Veilborn Godot project"
    exit 1
  fi
  
  echo "Exporting headless server binary..."
  cd "$GAME_DIR"
  "$GODOT_BIN" \
    --headless \
    --export-release "Linux/X11" \
    "$EXPORT_DIR/veilborn_server.x86_64" \
    2>&1 | tail -20
  
  if [[ ! -f "$EXPORT_DIR/veilborn_server.x86_64" ]]; then
    echo "ERROR: Export failed — binary not found"
    exit 1
  fi
  chmod +x "$EXPORT_DIR/veilborn_server.x86_64"
  ls -lh "$EXPORT_DIR/"
  echo "✓ Export complete"
  echo ""
fi

# ─── Step 2: Build & push Docker image ───────────────────────────────────────
if [[ "$SKIP_BUILD" == "false" ]]; then
  echo "━━━ Step 2/5: Building Docker Image ━━━━━━━━━━━━━━━━"
  
  # Create ECR repository if it doesn't exist
  aws ecr describe-repositories \
    --repository-names "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'repositories[0].repositoryUri' \
    --output text 2>/dev/null || \
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --query 'repository.repositoryUri' \
    --output text
  
  ECR_URI="$ECR_REGISTRY/$ECR_REPO"
  
  # Build
  echo "Building image $ECR_URI:$IMAGE_TAG..."
  docker build \
    --platform linux/amd64 \
    --build-arg GODOT_VERSION=4.3 \
    --build-arg GODOT_RELEASE=stable \
    -t "$ECR_URI:$IMAGE_TAG" \
    -t "$ECR_URI:$ENVIRONMENT-latest" \
    "$DOCKER_DIR"
  
  # Push
  echo "Logging in to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
  
  echo "Pushing $ECR_URI:$IMAGE_TAG..."
  docker push "$ECR_URI:$IMAGE_TAG"
  docker push "$ECR_URI:$ENVIRONMENT-latest"
  
  echo "✓ Image pushed: $ECR_URI:$IMAGE_TAG"
  echo ""
fi

# ─── Step 3: Terraform infrastructure ────────────────────────────────────────
if [[ "$SKIP_INFRA" == "false" ]]; then
  echo "━━━ Step 3/5: Terraform Infrastructure ━━━━━━━━━━━━━"
  
  cd "$INFRA_DIR"
  
  # Check for tfvars
  TFVARS="$INFRA_DIR/${ENVIRONMENT}.tfvars"
  if [[ ! -f "$TFVARS" ]]; then
    echo "ERROR: Missing $TFVARS"
    echo "Copy prod.tfvars.example to ${ENVIRONMENT}.tfvars and fill in your values"
    exit 1
  fi
  
  # Bootstrap S3 backend if needed
  BACKEND_BUCKET="veilborn-terraform-state"
  BACKEND_TABLE="veilborn-terraform-locks"
  
  aws s3api head-bucket --bucket "$BACKEND_BUCKET" 2>/dev/null || {
    echo "Creating Terraform state bucket..."
    aws s3api create-bucket \
      --bucket "$BACKEND_BUCKET" \
      --region "$AWS_REGION" \
      $([ "$AWS_REGION" != "us-east-1" ] && echo "--create-bucket-configuration LocationConstraint=$AWS_REGION" || echo "")
    aws s3api put-bucket-versioning \
      --bucket "$BACKEND_BUCKET" \
      --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption \
      --bucket "$BACKEND_BUCKET" \
      --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  }
  
  aws dynamodb describe-table \
    --table-name "$BACKEND_TABLE" \
    --region "$AWS_REGION" \
    --output text 2>/dev/null || {
    echo "Creating Terraform lock table..."
    aws dynamodb create-table \
      --table-name "$BACKEND_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$AWS_REGION"
  }
  
  terraform init -reconfigure
  terraform validate
  
  echo "Planning..."
  terraform plan \
    -var-file="$TFVARS" \
    -out="$ENVIRONMENT.tfplan" \
    -no-color 2>&1 | tail -30
  
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    echo ""
    echo "⚠️  PRODUCTION DEPLOYMENT"
    read -p "Apply these changes? (yes/no): " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
      echo "Aborted."
      exit 0
    fi
  fi
  
  echo "Applying..."
  terraform apply "$ENVIRONMENT.tfplan"
  
  # Capture outputs
  ASG_NAME=$(terraform output -raw asg_name)
  NLB_DNS=$(terraform output -raw nlb_dns_name)
  GAME_PORT=$(terraform output -raw game_server_connect_string | cut -d: -f2)
  
  echo ""
  echo "✓ Infrastructure applied"
  echo "  NLB: $NLB_DNS"
  echo "  ASG: $ASG_NAME"
  echo ""
fi

# ─── Step 4: Trigger rolling update on ASG ───────────────────────────────────
echo "━━━ Step 4/5: Rolling Update ━━━━━━━━━━━━━━━━━━━━━━━"

ASG_NAME="${ASG_NAME:-$(terraform -chdir="$INFRA_DIR" output -raw asg_name 2>/dev/null || echo '')}"

if [[ -n "$ASG_NAME" ]]; then
  echo "Starting instance refresh on $ASG_NAME..."
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --region "$AWS_REGION" \
    --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":120}' \
    --query 'InstanceRefreshId' \
    --output text
  echo "✓ Instance refresh started (rolling update in progress)"
else
  echo "WARN: Could not determine ASG name — skipping instance refresh"
fi

# ─── Step 5: Smoke test ───────────────────────────────────────────────────────
echo ""
echo "━━━ Step 5/5: Smoke Test ━━━━━━━━━━━━━━━━━━━━━━━━━━━"

NLB_DNS="${NLB_DNS:-$(terraform -chdir="$INFRA_DIR" output -raw nlb_dns_name 2>/dev/null || echo '')}"
ADMIN_PORT=8080

if [[ -n "$NLB_DNS" ]]; then
  echo "Waiting for health check at http://$NLB_DNS:$ADMIN_PORT/health ..."
  ATTEMPTS=0
  MAX_ATTEMPTS=20
  while [[ $ATTEMPTS -lt $MAX_ATTEMPTS ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 \
      "http://$NLB_DNS:$ADMIN_PORT/health" 2>/dev/null || echo "000")
    
    if [[ "$HTTP_CODE" == "200" ]]; then
      echo "✓ Health check passed (HTTP $HTTP_CODE)"
      break
    fi
    
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "  Attempt $ATTEMPTS/$MAX_ATTEMPTS — HTTP $HTTP_CODE — waiting 15s..."
    sleep 15
  done
  
  if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
    echo "WARN: Health check did not pass — instance may still be starting"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Deployment Complete! 🎮                 ║"
echo "╠══════════════════════════════════════════════════╣"
echo "║ Environment  : $ENVIRONMENT"
echo "║ Game Server  : ${NLB_DNS:-N/A}:${GAME_PORT:-7777}"
echo "║ CloudWatch   : https://$AWS_REGION.console.aws.amazon.com/cloudwatch"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Connect your Godot client to:"
echo "  ${NLB_DNS:-<NLB_DNS>}:${GAME_PORT:-7777}"
