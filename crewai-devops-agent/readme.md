## The core architectural difference — Strands vs CrewAI
**Strands** gives you one agent with all tools. The LLM decides everything in one ReAct loop — read pods, read logs, restart, scale, all in one pass. Simple, but the agent is doing everything.

**CrewAI** gives you a team. You define specialized agents with roles, goals, and backstories. Each agent only gets the tools relevant to its job. Tasks flow sequentially — the sre_analyst diagnoses first, then passes its full report as context to the remediation_engineer who acts on it. This mirrors how a real SRE team works.
The four tool functions in tools.py are identical between the two versions — only the import changes from from strands import tool to from crewai.tools import tool.

## Project structure
```
crewai-devops-agent/
├── agent/
│   ├── __init__.py    # exports run_diagnosis
│   ├── tools.py       # 4 K8s tools (same logic as Strands, different import)
│   ├── agents.py      # SRE Analyst + Remediation Engineer agent definitions
│   ├── tasks.py       # Diagnosis task + Remediation task definitions
│   └── crew.py        # Crew orchestrator + run_diagnosis() entry point
├── tests/
│   └── test_tools.py  # unit tests with mocked K8s
├── main.py            # HTTP server (BedrockAgentCoreApp wrapper)
├── run_agent.py       # local runner
├── requirements.txt
└── Dockerfile
```

## Step-by-step deployment
<details>
    <summary>Step 1 — Install and test locally</summary>

    # Create venv and install
    python -m venv .venv
    source .venv/Scripts/activate    # Windows Git Bash
    pip install -r requirements.txt

    # Run unit tests (no AWS or K8s needed)
    pytest tests/ -v

    # Run locally against your EKS cluster
    # (requires kubectl pointing at EKS + AWS credentials configured)
    python run_agent.py --namespace default
</details>

<details>
    <summary>Step 2 — Build and push to ECR (same commands as Strands version)</summary>

    # Get ECR URL from Terraform
    ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)

    # Auth Docker to ECR
    aws ecr get-login-password --region us-east-1 | \
    docker login --username AWS --password-stdin $ECR_URL

    # Build (--platform linux/amd64 required on Apple Silicon Macs)
    docker build --platform linux/amd64 -t $ECR_URL:latest .
    docker push $ECR_URL:latest
</details>

<details>
    <summary>Step 3 — Deploy to EKS (reuse the same K8s yamls — nothing changes)</summary>

    export ECR_URL=$(cd terraform && terraform output -raw ecr_repository_url)
    export AGENT_ROLE_ARN=$(cd terraform && terraform output -raw agent_role_arn)

    # RBAC (if not already applied)
    sed "s|\${AGENT_ROLE_ARN}|$AGENT_ROLE_ARN|g" k8s/rbac.yaml | kubectl apply -f -

    # Deploy
    envsubst < k8s/agent-deployment.yaml | kubectl apply -f -
    kubectl rollout status deployment/devops-agent --timeout=120s
</details>

<details>
    <summary>Step 4 — Invoke</summary>

    # Local run
    python run_agent.py

    # Via the running pod
    kubectl exec deployment/devops-agent -- python run_agent.py

    # Via HTTP (port-forward)
    kubectl port-forward svc/devops-agent-svc 8080:8080 &
    curl -s -X POST http://localhost:8080/invocations \
    -H "Content-Type: application/json" \
    -d '{"input_text": "diagnose default namespace", "namespace": "default"}'
</details>

## Key things to understand about CrewAI's Bedrock connection
**CrewAI** uses LiteLLM under the hood to interact with different LLM providers. The model string format for Bedrock is "bedrock/anthropic.claude-3-haiku-20240307-v1:0" GitHub — you set this once in agents.py and both agents share it. LiteLLM picks up your AWS credentials (IRSA in EKS, ~/.aws/credentials locally) automatically through boto3, so no API keys to manage.

The one thing to watch: CrewAI's first import initializes LiteLLM which is slightly slower than Strands on cold start — the startupProbe in the deployment yaml already has failureThreshold: 30 × 5s = 150 seconds of grace period, so this is covered.