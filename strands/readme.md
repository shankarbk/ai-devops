## What We're Building & Why
A tool-calling agent that reads K8s pod logs and metrics, identifies root causes (OOMKilled, CrashLoopBackOff, etc.), and autonomously runs remediation — pod restarts, HPA scaling, and alerting.

## Overview (Creating projct steps)
1. **Agent Framework**: Strands SDK   
    AWS's open-source Python SDK for building tool-calling agents. Clean, minimal, works natively with Bedrock models and AgentCore.

2. **Runtime**: EKS on t3.micro   
    Kubernetes cluster via custom Terraform (no pre-built modules). Sized for Free Tier — t3.micro nodes, minimal node group.

3. **Tools**: kubectl + CloudWatch   
    4 agent tools: get_pod_logs, get_pod_metrics, restart_pod, scale_deployment. Each mapped to a Python function.

4. **LLM**: Claude 3 Haiku        
    Cheapest Bedrock model. Perfect for structured reasoning over log data. Free Tier includes Bedrock API access in us-east-1.

5. **Hosting**: Bedrock AgentCore     
    Managed agent runtime that handles stateful sessions, tool routing, and invocation — no custom orchestration server needed.

## ***NOTE*** : Why Strands SDK over LangChain?   
- Strands is purpose-built for AWS Bedrock, has zero-config tool registration with Python decorators, and has a much smaller dependency footprint. LangChain works too, but adds 50+ transitive deps for features you won't use here.   

- Strands is AWS's own open-source agent SDK. Tools are just Python functions with @tool decorators — the framework reads your docstrings and type hints to auto-generate the JSON schemas the LLM uses to call them. Zero orchestration boilerplate.

- Why IRSA instead of IAM users?   
IAM Roles for Service Accounts (IRSA) lets your EKS pod assume an IAM role using Kubernetes's OIDC token — no long-lived credentials stored anywhere. This is the production-correct way to grant pods AWS permissions.

- Why Claude 3 Haiku LLM model ?   
It's 12× cheaper than Sonnet and structured log analysis (pattern matching, JSON extraction, decision trees) is well within its capabilities. Use Sonnet only if you need complex multi-document reasoning.

## Complete Data Flow (Agent Lifecycle):
```
User/Scheduler → AgentCore Invoke
    → Agent receives prompt: "Check all pods in namespace 'prod'"
    → LLM decides: call get_pod_logs(namespace="prod")
    → Tool executes: kubectl logs pod/xxx --tail=100
    → LLM analyzes output: detects "OOMKilled" pattern
    → LLM decides: call get_pod_metrics(pod_name="xxx")
    → Tool executes: kubectl top pod xxx
    → LLM reasons: memory limit exceeded, recommend restart + scale
    → LLM decides: call restart_pod(pod_name="xxx")
    → Tool executes: kubectl delete pod xxx (K8s recreates it)
    → LLM decides: call scale_deployment(name="xxx", replicas=3)
    → Final response: structured diagnosis + actions taken
```

## Project Directory Structure
```
devops-agent/
├── agent/
│   ├── __init__.py
│   ├── agent.py          # Core agent definition
│   ├── tools.py          # All 4 kubectl tools
│   ├── prompts.py        # System prompt
│   └── config.py         # AWS region, model, namespace
├── tests/
│   ├── test_tools.py     # Unit tests with mocked kubectl
│   ├── test_agent.py     # Integration test (local Bedrock)
│   └── mock_k8s/         # Fake pod log fixtures
├── terraform/
│   ├── main.tf           # VPC + EKS cluster (raw resources)
│   ├── variables.tf
│   ├── outputs.tf
│   └── iam.tf            # Node role, IRSA for agent
├── k8s/
│   ├── sample-app.yaml   # Intentionally broken deployment
│   └── rbac.yaml         # Agent ServiceAccount + ClusterRole
├── Dockerfile
├── requirements.txt
└── deploy_agentcore.py   # Registers agent with Bedrock
```

## Let's start

<details>
  <summary> PHASE 1 : Build the Agent with Strands SDK  </summary>

1. Install dependencies - requirements.txt + install

    - We write the agent core — tools, system prompt, and agent loop — in pure Python before touching any AWS infra. This is the brain of everything.

    - Why Strands SDK?   
    It's AWS's own open-source agent SDK (released 2024). Tools are just Python functions decorated with @tool. The framework handles all the ReAct reasoning loop — you write business logic, not orchestration plumbing.   

2. Write the 4 agent tools - agent/tools.py   

    - Why the @tool decorator?   
    Strands reads the function's docstring and type annotations to auto-generate the JSON schema that gets sent to the LLM. The LLM uses that schema to know when and how to call each tool. Rich docstrings = better LLM decisions.    

3. Write the system prompt - agent/prompts.py   

    - Why a structured system prompt?   
    The LLM needs to know the "rules of engagement." Without guardrails it might restart healthy pods, scale to 0 replicas, or act on kube-system pods. The prompt is your safety layer — be explicit about what NOT to do.

4. Wire up the agent (agent/agent.py)
 
5. Config file (agent/config.py)  

</details>

<details>
  <summary>PHASE 2 : Local Agent Testing   </summary>

  Test the agent locally with mocked Kubernetes responses before spending money on EKS. You need only AWS credentials configured — no actual K8s cluster required for unit tests.
 
1. Unit test tools with mocked K8s (tests/test_tools.py)
    - Why mock at the module level?   
    The kubernetes SDK tries to connect to a cluster on import. We patch before import to prevent that. Then we patch the module-level v1 and apps_v1 objects individually per test to control exact responses.

2. Integration test against real Bedrock (tests/test_agent.py)
    - Prerequisites: AWS credentials configured (aws configure). Bedrock model access enabled in us-east-1 console → Bedrock → Model Access → Enable Claude 3 Haiku.   
    ```
        # Run just this test:
        # pytest tests/test_agent.py -v -s
    ```

3. Run tests locally

    - Unit tests only (no AWS calls)
        > pytest tests/test_tools.py -v

    - Integration test (calls real Bedrock ~$0.001)
        >pytest tests/test_agent.py -v -s

    - Quick CLI smoke test — talk to the agent directly
        >python -c "   
        >from agent.agent import run_diagnosis   
        >print(run_diagnosis('List all pods and tell me which ones need attention'))   
        >"   

</details>

<details>
  <summary>PHASE 3 : EKS Cluster with Terraform (No Pre-built Modules) </summary>

- Build every resource from scratch

- ***Cost warning***: An EKS cluster costs $0.10/hour (~$72/month) just for the control plane. Add t3.micro nodes (~$0.0104/hr each). Destroy the cluster after learning! terraform destroy

1. VPC + Subnets (terraform/main.tf, provider.tf — Part 1)
    - Why public subnets only?    
        Private subnets require a NAT Gateway ($0.045/hr = ~$33/month).   
        For learning, public subnets with a strict security group is fine. In production, use private subnets + NAT for node security.

2. IAM Roles for EKS (terraform/iam.tf)
    - Why IRSA?   
        Without IRSA, you'd need to put AWS access keys in a Secret or env var — a security anti-pattern.   
        IRSA uses K8s's OIDC token to get temporary credentials from STS. The pod automatically rotates credentials every hour. Zero secrets stored anywhere.

        **Extra IMP Points** :   
        
        - What is OIDC ?
            In Kubernetes (K8s), OIDC stands for OpenID Connect. It is an identity layer built on top of the OAuth 2.0 framework that allows the cluster to verify a user's identity through an external provider.   
            
        - What is an OIDC Token?   
            An OIDC token, specifically called an ID Token, is a JSON Web Token (JWT) that contains cryptographically signed "claims" about a user, such as their username, email, or group memberships.   

        - How it Works in Kubernetes   
        
            Authentication:   
            When you run a command like "kubectl get pods", you provide this ID Token. The Kubernetes API server validates the token's signature against your Identity Provider (IdP) (e.g., Google, Okta, or Keycloak) to confirm who you are.   

            Authorization:   
            Once identified, Kubernetes uses its internal Role-Based Access Control (RBAC) to check the token's "groups" or "user" claims and decide what you are allowed to do.    
            
            Key Benefits:   
                Single Sign-On (SSO): Use your existing corporate credentials (like Azure AD or Okta) to access the cluster.   
                Security: Avoids sharing static, long-lived certificates or passwords by using short-lived, verifiable tokens.   
                Centralization: User and group management happens in the Identity Provider, not manually inside every cluster

3. EKS Cluster + Node Group (terraform/eks.tf — Part 2)

4. Variables & Outputs ( terraform/variables.tf, terraform/outputs.tf)

5. Apply the infrastructure ( terraform/instructions.txt)

6. Deploy a broken app for the agent to fix (k8s/sample-app.yaml)
</details>

<details>
  <summary>PHASE 4 : Amazon Bedrock AgentCore Integration   </summary>

Deploy your agent to AgentCore — a fully managed runtime that hosts your agent, handles invocations, manages sessions, and integrates with AWS security. No custom servers to maintain.

- What is AgentCore?   
It's AWS's managed platform for hosting AI agents. You push your agent code as a container image, and AgentCore handles the HTTP endpoint, session state, tool routing, IAM auth, and auto-scaling. Think Lambda Functions but purpose-built for agents with multi-turn reasoning.

1. Containerize the agent (Dockerfile)

2. AgentCore entry point (main.py)

3. Build, push to ECR, and register with AgentCore

4. Invoke the agent (invoke_agent.py)

</details>








## Free Tier & Cost Management
Every resource decision made in this guide is cost-optimized. Here's the full breakdown with strategies to minimize spend.

|Service	|What We Use	|Free Tier?	|Est. Cost|
|----------|----------|----------|----------|
|EKS Control Plane|	1 cluster, always-on|	Paid|	$0.10/hr ($72/mo)|
|EC2 Nodes|	2× t3.micro|	Free Tier|	$0 (750 hrs/mo)|
|Bedrock - Claude Haiku|	~10 diagnoses/day|	Free Tier|	~$0.05/day|
|Bedrock AgentCore|	Pay per invocation|	Low Cost|	~$0.001/invocation|
|ECR	|1 image ~500MB	|Free Tier|	$0 (500MB free)|
|VPC/Networking|	Public subnets, no NAT|	Free Tier|	$0 (no NAT GW)|
|CloudWatchLogs|	EKS control plane logs off|	Free Tier|	$0 (5GB free)|

> **NOTE** : Biggest cost: EKS Control Plane = $0.10/hr. Always run terraform destroy after your learning session. The control plane charges even when idle. Set a calendar reminder!

1. Destroy EKS after each session

    - Save $0.10/hr when not actively learning
        > cd terraform && terraform destroy -auto-approve

    - Re-create when you need it (takes ~15 min)
        > terraform apply -auto-approve

2. Use Bedrock Playground for initial LLM testing   
    **Free testing tip**: Test your prompts and tool calling logic in the Bedrock console Playground before running your full agent. Console testing is free and lets you tune your system prompt without code changes.

3. Keep logs disabled during dev   
main.tf — add to aws_eks_cluster   
```
# Don't enable these unless you need to debug — each adds CloudWatch cost
enabled_cluster_log_types = []  # options: api, audit, authenticator, controllerManager, scheduler
```

4. Use Haiku not Sonnet for all production runs   
    - Claude 3 Haiku ✓ Use this   
        $0.00025/1K input, $0.00125/1K output. Fast (200ms). Perfect for structured log analysis. 200K context window.

    - Claude 3 Sonnet ✗ Avoid   
        $0.003/1K input (12× more expensive). Only worth it for very complex multi-step reasoning tasks.

* Learning Sequence Recommendation   
    - Day 1: Write agent code + unit tests (zero AWS cost)
    - Day 2: Integration test with real Bedrock, no EKS (~$0.05 total)
    - Day 3: Create EKS, deploy broken app, invoke agent locally → destroy EKS (~$2 total)
    - Day 4: Full AgentCore deploy for 2 hours → destroy (~$0.80 total)   
    Total estimated spend for complete hands-on: ~$5–10