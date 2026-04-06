# Local agent setup and run — step by step
# Run all commands from your project root (where agent/ folder is)

# ── 1. Create and activate virtual environment ─────────────────────────────

# Windows (Git Bash / MINGW64):
python -m venv .venv
source .venv/Scripts/activate

# Mac / Linux:
# python -m venv .venv
# source .venv/bin/activate

# Confirm you're inside the venv (should show .venv path):
which python


# ── 2. Install dependencies ────────────────────────────────────────────────

pip install -r requirements.txt

# If requirements.txt is missing, install manually:
# pip install bedrock-agentcore strands-agents boto3 kubernetes pydantic uvicorn


# ── 3. Verify AWS credentials are working ─────────────────────────────────

aws sts get-caller-identity
# Must return your Account ID. If error → run 'aws configure' first.

# Verify Bedrock model access (must have Claude 3 Haiku enabled in console):
aws bedrock list-foundation-models \
  --region us-east-1 \
  --query "modelSummaries[?contains(modelId,'haiku')].modelId" \
  --output table


# ── 4. Verify kubectl points at EKS ───────────────────────────────────────

kubectl config current-context
# Should show: arn:aws:eks:us-east-1:XXXX:cluster/devops-agent
# If it shows 'kind-kind' → switch context:
# aws eks update-kubeconfig --region us-east-1 --name devops-agent

kubectl get pods
# Should show your EKS pods (broken-api, devops-agent, etc.)


# ── 5. Run the agent ──────────────────────────────────────────────────────

# Default prompt (full diagnosis + remediation):
python run_agent.py

# Custom prompts:
python run_agent.py "list all pods and show their status"
python run_agent.py "diagnose the broken-api pod"
python run_agent.py "scale the broken-api deployment to 2 replicas"


# ── TROUBLESHOOTING ───────────────────────────────────────────────────────

# Error: ModuleNotFoundError: No module named 'agent'
#   → You're not in the project root. Run: cd /path/to/your/project
#   → Check the folder structure: ls  (should see agent/ folder here)

# Error: ModuleNotFoundError: No module named 'strands'
#   → Venv not activated. Run: source .venv/Scripts/activate  (Windows)
#   → Then: pip install -r requirements.txt

# Error: botocore.exceptions.NoCredentialsError
#   → AWS credentials not configured. Run: aws configure

# Error: kubernetes.config.config_exception.ConfigException
#   → kubectl not pointing at EKS.
#   → Run: aws eks update-kubeconfig --region us-east-1 --name devops-agent

# Error: could not find model / AccessDeniedException
#   → Bedrock model access not enabled.
#   → Go to: AWS Console → Bedrock → Model access → Enable Claude 3 Haiku
