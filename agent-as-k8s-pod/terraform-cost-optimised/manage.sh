#!/usr/bin/env bash
###############################################################################
# manage.sh — Lifecycle script for the DevOps Agent EKS cluster
#
# PURPOSE: Makes it dead-simple to spin up and destroy the cluster.
#          The EKS control plane costs $0.10/hr. This script makes it
#          easy to destroy when done and recreate when you need it.
#
# USAGE:
#   ./manage.sh up       — create cluster + configure kubectl (~15 min)
#   ./manage.sh down     — destroy everything to stop charges
#   ./manage.sh status   — show what's running and estimated charges
#   ./manage.sh deploy   — build image, push to ECR, apply K8s manifests
#   ./manage.sh invoke   — invoke the agent with a test prompt
#
# COST GUARD: The script shows an hourly cost reminder before creating
#             and asks for confirmation before destroy.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${SCRIPT_DIR}"
K8S_DIR="${SCRIPT_DIR}/../k8s"
AGENT_DIR="${SCRIPT_DIR}/../agent"

# Colors for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

banner() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║  DevOps Agent EKS Lifecycle Manager      ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
  echo ""
}

check_prerequisites() {
  info "Checking prerequisites..."
  local missing=()

  command -v terraform &>/dev/null || missing+=("terraform")
  command -v aws       &>/dev/null || missing+=("aws-cli")
  command -v kubectl   &>/dev/null || missing+=("kubectl")
  command -v docker    &>/dev/null || missing+=("docker")

  if [ ${#missing[@]} -gt 0 ]; then
    err "Missing required tools: ${missing[*]}\nInstall guide: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  fi

  # Check AWS credentials
  if ! aws sts get-caller-identity &>/dev/null; then
    err "AWS credentials not configured. Run: aws configure"
  fi

  log "All prerequisites met"
}

cmd_up() {
  banner
  check_prerequisites

  echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║  COST REMINDER                                       ║${NC}"
  echo -e "${YELLOW}║  EKS control plane = \$0.10/hr while cluster exists   ║${NC}"
  echo -e "${YELLOW}║  t3.micro nodes    = \$0.00/hr (Free Tier)            ║${NC}"
  echo -e "${YELLOW}║  A 2-hour session  = ~\$0.20                          ║${NC}"
  echo -e "${YELLOW}║  Run './manage.sh down' when done to stop charges!   ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""

  read -rp "Proceed? (yes/no): " confirm
  [[ "$confirm" == "yes" ]] || { warn "Aborted."; exit 0; }

  # Copy example tfvars if none exists
  if [ ! -f "${TF_DIR}/terraform.tfvars" ]; then
    warn "No terraform.tfvars found. Creating from example..."
    cp "${TF_DIR}/terraform.tfvars.example" "${TF_DIR}/terraform.tfvars"
    warn "Edit terraform.tfvars to set your IP in allowed_cidr, then re-run."
    exit 0
  fi

  info "Initializing Terraform..."
  cd "${TF_DIR}"
  terraform init -upgrade

  info "Planning infrastructure..."
  terraform plan -out=tfplan

  info "Creating EKS cluster (this takes 12-18 minutes)..."
  START_TIME=$(date +%s)
  terraform apply tfplan

  END_TIME=$(date +%s)
  ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
  log "Cluster created in ${ELAPSED} minutes"

  # Configure kubectl automatically
  CLUSTER_NAME=$(terraform output -raw cluster_name)
  AWS_REGION=$(terraform output -raw cluster_name 2>/dev/null || echo "us-east-1")
  CONFIGURE_CMD=$(terraform output -raw cmd_configure_kubectl)

  info "Configuring kubectl..."
  eval "$CONFIGURE_CMD"

  info "Waiting for nodes to be ready (up to 5 minutes)..."
  kubectl wait --for=condition=ready node --all --timeout=300s

  log "Cluster is ready!"
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo "  1. Run: ./manage.sh deploy   → build and deploy the agent"
  echo "  2. Run: ./manage.sh invoke   → test the agent"
  echo "  3. Run: ./manage.sh down     → destroy when done (IMPORTANT!)"
  echo ""
  
  # Show running timer reminder
  warn "Cluster is charging at \$0.10/hr. Timer started at $(date '+%H:%M')."
}

cmd_down() {
  banner
  check_prerequisites

  echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║  DESTROYING ALL INFRASTRUCTURE                       ║${NC}"
  echo -e "${RED}║  This will delete: EKS cluster, nodes, VPC, ECR     ║${NC}"
  echo -e "${RED}║  Your agent code files will NOT be deleted.          ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""

  read -rp "Type 'destroy' to confirm: " confirm
  [[ "$confirm" == "destroy" ]] || { warn "Aborted. Cluster still running."; exit 0; }

  cd "${TF_DIR}"

  info "Destroying infrastructure..."
  terraform destroy -auto-approve

  log "All infrastructure destroyed. No more charges from EKS."
  log "Your Terraform state is preserved — you can recreate with: ./manage.sh up"
}

cmd_status() {
  banner

  info "Checking Terraform state..."
  cd "${TF_DIR}"

  if ! terraform output cluster_name &>/dev/null 2>&1; then
    warn "No active cluster found in Terraform state."
    echo "Run: ./manage.sh up"
    exit 0
  fi

  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "unknown")
  
  info "Checking EKS cluster status..."
  CLUSTER_STATUS=$(aws eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")
  
  if [ "$CLUSTER_STATUS" == "ACTIVE" ]; then
    echo -e "${GREEN}Cluster: ACTIVE${NC} — ${RED}charging \$0.10/hr${NC}"
    echo ""
    echo "Nodes:"
    kubectl get nodes -o wide 2>/dev/null || warn "kubectl not configured. Run: $(terraform output -raw cmd_configure_kubectl)"
    echo ""
    echo "Pods:"
    kubectl get pods -A 2>/dev/null || true
  elif [ "$CLUSTER_STATUS" == "NOT_FOUND" ]; then
    echo -e "${GREEN}Cluster: DESTROYED${NC} — ${GREEN}not charging${NC}"
  else
    echo -e "${YELLOW}Cluster status: ${CLUSTER_STATUS}${NC}"
  fi
}

cmd_deploy() {
  banner
  check_prerequisites

  cd "${TF_DIR}"

  # Get outputs from Terraform
  ECR_URL=$(terraform output -raw ecr_repository_url)
  AGENT_ROLE_ARN=$(terraform output -raw agent_role_arn)
  CLUSTER_NAME=$(terraform output -raw cluster_name)

  info "Authenticating Docker to ECR..."
  REGION=$(terraform output -raw cluster_name 2>/dev/null || echo "us-east-1")
  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  
  aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin "${ECR_URL}"

  info "Building agent Docker image..."
  cd "${SCRIPT_DIR}/.."
  docker build \
    --platform linux/amd64 \
    --tag "${ECR_URL}:latest" \
    --file Dockerfile \
    .

  info "Pushing image to ECR..."
  docker push "${ECR_URL}:latest"
  log "Image pushed: ${ECR_URL}:latest"

  info "Applying Kubernetes RBAC..."
  # envsubst replaces ${AGENT_ROLE_ARN} in the yaml with actual value
  export AGENT_ROLE_ARN
  envsubst < "${K8S_DIR}/rbac.yaml" | kubectl apply -f -

  info "Deploying broken test app (agent will diagnose this)..."
  kubectl apply -f "${K8S_DIR}/broken-app.yaml"

  info "Deploying agent..."
  # Replace ECR_URL and AGENT_ROLE_ARN placeholders in the deployment yaml
  export ECR_URL AGENT_ROLE_ARN
  envsubst < "${K8S_DIR}/agent-deployment.yaml" | kubectl apply -f -

  info "Waiting for agent pod to be ready..."
  kubectl rollout status deployment/devops-agent --timeout=120s

  log "Deployment complete!"
  kubectl get pods
}

cmd_invoke() {
  banner

  PROMPT="${1:-Diagnose all pods in the default namespace and fix any issues you find.}"
  
  info "Invoking agent with prompt:"
  echo "  \"${PROMPT}\""
  echo ""

  # Run a temporary pod to invoke the agent directly
  kubectl run agent-invoke \
    --image="curlimages/curl:latest" \
    --restart=Never \
    --rm \
    --attach \
    --command -- sh -c "
      curl -s -X POST http://devops-agent-svc:8080/invocations \
        -H 'Content-Type: application/json' \
        -d '{\"input_text\": \"${PROMPT}\"}' | jq .
    " 2>/dev/null || true
}

# ── Main dispatcher ────────────────────────────────────────────────────────
COMMAND="${1:-help}"

case "$COMMAND" in
  up)     cmd_up     ;;
  down)   cmd_down   ;;
  status) cmd_status ;;
  deploy) cmd_deploy ;;
  invoke) cmd_invoke "${2:-}" ;;
  help|*)
    banner
    echo "Usage: ./manage.sh <command>"
    echo ""
    echo "Commands:"
    echo "  up       Create EKS cluster (~15 min, costs \$0.10/hr while running)"
    echo "  down     Destroy all infrastructure (stops all charges)"
    echo "  status   Show cluster status and running pods"
    echo "  deploy   Build image, push to ECR, apply K8s manifests"
    echo "  invoke   Send a test prompt to the running agent"
    echo ""
    echo "Recommended workflow:"
    echo "  1. ./manage.sh up"
    echo "  2. ./manage.sh deploy"
    echo "  3. ./manage.sh invoke"
    echo "  4. ./manage.sh down   ← DON'T FORGET THIS"
    ;;
esac
