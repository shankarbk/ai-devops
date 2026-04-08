## What We're Building & Why
A tool-calling agent that reads K8s pod logs and metrics, identifies root causes (OOMKilled, CrashLoopBackOff, etc.), and autonomously runs remediation — pod restarts, HPA scaling, and alerting.

## what we're building ?
- A Agent, which runs as a Pod inside Kubernetes.
- We manage the container, the Dockerfile, the Deployment yaml
- We own the infrastructure (nodes, networking, scaling)
- Agent calls Bedrock API to use Claude as its LLM
- Agent calls Kubernetes API to diagnose and fix pods
- Invoked via kubectl exec, curl, or port-forward

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
│   ├── broken-app.yaml   # Intentionally broken deployment
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
  <summary>PHASE 3 : EKS Cluster with Terraform (No Pre-built Modules) --> terraform-cost-optimised</summary>

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

6. Deploy a broken app for the agent to fix (k8s/broken-app.yaml)   
    <details>
    <summary>Deployment steps</summary>

    1. **Prerequisites — what you need on your laptop**   
        kubectl, AWS CLI and eksctl (optional but useful). Everything runs from your local terminal.
        1. Check what you already have
            ```
            # Check kubectl — you already have this from kind
            kubectl version --client
            # Expected: Client Version: v1.xx.x

            # Check AWS CLI
            aws --version
            # If missing, install: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html

            # Check if AWS credentials are configured
            aws sts get-caller-identity
            # Expected: {"UserId": "...", "Account": "123456789012", "Arn": "arn:aws:iam::..."}
            # If error: run 'aws configure' and enter your Access Key ID + Secret
            ```
        2. Configure AWS credentials (if needed)
            ```
            aws configure
            # AWS Access Key ID: AKIA...your key...
            # AWS Secret Access Key: ...your secret...
            # Default region name: us-east-1
            # Default output format: json

            # Verify it works
            aws sts get-caller-identity
            ```

        3. Run Terraform to create the EKS cluster
            ```
            cd terraform/
            cp terraform.tfvars.example terraform.tfvars

            # Edit terraform.tfvars — set your IP for security
            # allowed_cidr = "$(curl -s ifconfig.me)/32"

            terraform init
            terraform apply -auto-approve

            # Takes 12–18 minutes. Get a coffee.
            # When done, you'll see outputs including cmd_configure_kubectl
            ```

    2. **Connect kubectl to your EKS cluster**
        - With kind you ran kind "create cluster" and kubectl auto-configured. With EKS, you run one AWS CLI command that does the same thing — writes a context into your ~/.kube/config.
        1. Point your local kubectl to EKS
            ```
            # This command fetches the cluster endpoint + auth token from AWS
            # and writes a new context into ~/.kube/config to of your local system.
            # It's the EKS equivalent of 'kind create cluster' auto-configuring kubectl

            aws eks update-kubeconfig --region us-east-1 --name devops-agent-cluster

            # Expected output:
            # Added new context arn:aws:eks:us-east-1:123456789:cluster/devops-agent to ~/.kube/config
            ```
        2. Verify the connection (identical to kind!)
            ```
            # Exact same commands you use with kind
            kubectl get nodes
            # NAME                          STATUS   ROLES    AGE   VERSION
            # ip-10-0-1-45.ec2.internal     Ready    <none>   3m    v1.29.x
            # ip-10-0-1-50.ec2.internal     Ready    <none>   3m    v1.29.x

            kubectl get pods -A
            # NAMESPACE     NAME                      READY   STATUS    RESTARTS
            # kube-system   aws-node-xxxxx            1/1     Running   0
            # kube-system   coredns-xxxxxxx           1/1     Running   0
            # kube-system   kube-proxy-xxxxx          1/1     Running   0

            # Check current context (like 'kind-kind' for kind clusters)
            kubectl config current-context
            # arn:aws:eks:us-east-1:123456789:cluster/devops-agent-cluster
            ```   
        
            It really is that simple. Once update-kubeconfig runs, every kubectl command you know from kind works identically on EKS. The auth happens transparently via your AWS credentials.


        3. Switching between kind and EKS contexts
            ```
            # List all contexts in your kubeconfig
            kubectl config get-contexts

            # Switch back to your kind cluster
            kubectl config use-context kind-kind

            # Switch to EKS
            kubectl config use-context arn:aws:eks:us-east-1:123456789:cluster/devops-agent

            # Tip: alias long EKS context names
            kubectl config rename-context arn:aws:eks:us-east-1:123456789:cluster/devops-agent-cluster devops-eks
            ```

    3. **Write the Kubernetes YAML files**   
        Three files: the broken app that will OOMKill, the RBAC so the agent has permission to act, and the agent deployment itself. Create a k8s/ folder in your project root.   (k8s/broken-app.yaml, k8s/rbac.yaml, k8s/agent-deployment.yaml)

        - what "k8s/broken-app.yaml" does ? : A Python process that allocates 1MB of RAM every 10ms with no upper bound. The container memory limit is 60Mi, so it will OOMKill in under a minute and enter CrashLoopBackOff — exactly what the agent will diagnose and fix.

        - Why RBAC ? : By default, a pod has no permission to call the Kubernetes API. Without this, when the agent calls kubectl delete pod via the Python SDK, it gets a 403 Forbidden. RBAC grants exactly the permissions needed — nothing more.

    4. **Deploy everything — step by step**   
        All commands from your laptop. Terraform outputs the values you need, then kubectl does the rest — same commands as kind.
        1. Get values from Terraform
            ```
            cd terraform/
            # Get the IAM role ARN for the agent ServiceAccount
            AGENT_ROLE_ARN=$(terraform output -raw agent_role_arn)
            echo $AGENT_ROLE_ARN
            # arn:aws:iam::123456789:role/devops-agent-agent-pod-role

            # Get ECR URL for the agent image
            ECR_URL=$(terraform output -raw ecr_repository_url)
            echo $ECR_URL
            # 123456789.dkr.ecr.us-east-1.amazonaws.com/devops-agent-agent

            cd ..
            ```
        2. Deploy the broken app (nothing to build, uses public image)
            ```
            # Same as 'kubectl apply -f' with kind — no difference at all
            kubectl apply -f k8s/broken-app.yaml

            # Expected output:
            # deployment.apps/broken-api created
            ```
        3. Apply RBAC (substitute the IAM role ARN)   
            What envsubst does: It replaces ${AGENT_ROLE_ARN} in the YAML file with the actual ARN from your environment variable, then pipes the result to kubectl. No manual text editing needed.

            ```
            # export so envsubst can see them
            export AGENT_ROLE_ARN ECR_URL

            # envsubst replaces ${AGENT_ROLE_ARN} in the yaml with the real value
            envsubst < k8s/rbac.yaml | kubectl apply -f -

            # Expected output:
            # serviceaccount/devops-agent-sa created
            # clusterrole.rbac.authorization.k8s.io/devops-agent-role created
            # clusterrolebinding.rbac.authorization.k8s.io/devops-agent-binding created

            # Verify ServiceAccount was created with the annotation
            kubectl get serviceaccount devops-agent-sa -o yaml
            # Look for: eks.amazonaws.com/role-arn: arn:aws:iam::...
            ```   

            If you don't have envsubst (macOS users): install with brew install gettext. Alternative: manually replace ${AGENT_ROLE_ARN} in rbac.yaml with the actual ARN and apply directly.

        4. Build and push the agent image to ECR
            ```
            # Step 1: Authenticate Docker to ECR (token valid 12 hours)
            aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_URL

            # Step 2: Build the agent image (Your local docker should be running)
            # --platform linux/amd64: EKS nodes run x86_64, even on Apple Silicon Macs   
            docker build --platform linux/amd64 -t $ECR_URL:latest .

            # Step 3: Push to ECR
            docker push $ECR_URL:latest

            # Verify image is in ECR
            aws ecr describe-images --repository-name devops-agent-cluster-agent --query 'imageDetails[*].[imageTags,imageSizeInBytes]'
            ```

        5. Deploy the agent   
            Use the Deployment(k8s/agent-deployment.yaml) if someone calls the agent on demand to fix a specific issue.   
            Use the CronJob(k8s/agent-cron.yaml) if the agent runs autonomously on a schedule and no human is triggering it. CronJob also sidesteps the "pod is always running" concern entirely — the pod only exists for ~30 seconds per run, crash-restarts are handled by restartPolicy: OnFailure, and there's nothing idle consuming pod slots.   
            
            ```
            # Substitute ECR_URL into the deployment yaml and apply
            envsubst < k8s/agent-deployment.yaml | kubectl apply -f -

            # Verify probes are wired up
            kubectl describe pod -l app=devops-agent | grep -A 6 "Liveness\|Readiness\|Startup"

            # Expected:
            # deployment.apps/devops-agent created
            # service/devops-agent-svc created

            # Wait for agent pod to be Running
            kubectl rollout status deployment/devops-agent --timeout=120s
            # Waiting for deployment "devops-agent" rollout to finish...
            # deployment "devops-agent" successfully rolled out

            Faced Issues :
            1. Warning  FailedScheduling  103s  default-scheduler  0/1 nodes are available: 1 Too many pods. no new claims to deallocate, preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
            Resolution : Every pod on EKS needs its own private IP address from the VPC. AWS allocates IPs based on the number of ENIs an instance can hold. t3.micro maxes out at 4 pods total. so changed from desired state of nodes 1 to 2 "aws_eks_node_group"
            ```

    5. **Watch the broken app fail in real time**
        1. Watch pod status in real time   
            ```
            # -w flag = watch mode. Updates live. Ctrl+C to stop.
            kubectl get pods -w

            # You'll see this progression over ~90 seconds:
            #
            # NAME                          READY   STATUS              RESTARTS   AGE
            # broken-api-7d4f8b-abc12       0/1     ContainerCreating   0          5s
            # broken-api-7d4f8b-abc12       1/1     Running             0          12s
            # broken-api-7d4f8b-abc12       0/1     OOMKilled           0          38s    <-- memory limit hit!
            # broken-api-7d4f8b-abc12       0/1     CrashLoopBackOff    1          45s    <-- K8s backs off restarts
            # broken-api-7d4f8b-abc12       1/1     Running             1          75s    <-- K8s retries
            # broken-api-7d4f8b-abc12       0/1     OOMKilled           1          112s   <-- OOMKill again
            ```
        
        2. Read the pod logs (what the agent's tool sees)   
            ```
            # Get the exact pod name first
            POD_NAME=$(kubectl get pods -l app=broken-api -o jsonpath='{.items[0].metadata.name}')
            echo $POD_NAME

            # Read logs — same command the agent's get_pod_logs() tool runs
            kubectl logs $POD_NAME --tail=20

            # Expected output:
            # Starting memory leak simulation...
            # Allocated 1MB so far
            # Allocated 2MB so far
            # ...
            # Allocated 47MB so far
            # Killed                          <-- OOMKill. No Python traceback, just "Killed"

            # Read previous container's logs (after a crash+restart)
            kubectl logs $POD_NAME --previous --tail=20
            ```

        3. Inspect the OOMKill reason (what the agent's get_pods_status() sees)   
            ```
            # Describe shows the full pod state including last termination reason
            kubectl describe pod $POD_NAME

            # Look for this section in the output:
            #   Last State: Terminated
            #     Reason:   OOMKilled          <-- This is what the agent detects
            #     Exit Code: 137               <-- 128 + SIGKILL signal number
            #     Started:   Mon, 15 Jan 2024 10:23:44 +0000
            #     Finished:  Mon, 15 Jan 2024 10:24:22 +0000

            # Also useful — events show the K8s controller's perspective
            kubectl get events --sort-by='.lastTimestamp'
            # You'll see: BackOff, Started, Pulling, OOMKilling events
            ```                   

        4. Confirm the full picture before running the agent
            ```
            # Quick health check — what you should see before running the agent
            kubectl get pods

            # NAME                          READY   STATUS             RESTARTS   AGE
            # broken-api-7d4f8b-abc12       0/1     CrashLoopBackOff   5          8m    ← agent will fix this
            # devops-agent-xxx              1/1     Running            0          3m    ← this is the agent
            ```

    6. **Run the agent and watch it self-heal**   
        Two options: invoke locally (faster for testing), or invoke via the running pod. Both hit the same agent logic.

        1. Create .venv and install packages
            ```
            python -m venv .venv

            source .venv/bin/activate       - Linux 
            .venv\Scripts\activate          - windows
            .\.venv\Scripts\Activate.ps1    - powershell

            pip install -r requirements.txt

            ```

        2. Option A: Run agent directly from your laptop (easiest)   
            This works because: your laptop has AWS credentials + your kubeconfig already points at EKS. The agent Python code uses both — boto3 for Bedrock, kubernetes SDK for K8s API. No pod needed.   
            ```
            # Make sure you're in the project root with your venv active cd devops-agent/ source venv/bin/activate # or: .venv/bin/activate 
            # Run the agent pointing at your EKS cluster # It uses ~/.kube/config (already pointing at EKS) and your AWS creds. 
            # Run Below command
            python -c "
            from agent.agent import run_diagnosis
            result = run_diagnosis('Diagnose all pods in the default namespace. Fix any pods that are failing. Provide a detailed report.')
            print(result)
            "

            OR

            Refer  : run_local.sh
            ```

        3. Option B: Run via the agent pod (production path)   
            ```
            # Get agent pod name AGENT_POD=$(kubectl get pods -l app=devops-agent -o jsonpath='{.items[0].metadata.name}') 
            # Run diagnosis via exec into the agent pod : 
            kubectl exec $AGENT_POD -- python -c "from agent.agent import run_diagnosis print(run_diagnosis('Diagnose default namespace and fix failing 
            pods'))" 
            
            # Or 
            
            POST to the HTTP endpoint via port-forward : kubectl port-forward svc/devops-agent-svc 8080:8080 & curl -s -X POST http://localhost:8080/invocations \ -H 'Content-Type: application/json' \ -d '{"input_text": "Diagnose all pods and fix issues"}' | python -m json.tool
            ```

        4. What to expect in the agent output
            ```
            Calling tool: get_pods_status(namespace="default")

            Tool result: [{"name": "broken-api-7d4f-abc", "phase": "Failed",
            "restart_count": 5, "last_termination_reason": ["OOMKilled"]}]

            Calling tool: get_pod_logs(pod_name="broken-api-7d4f-abc", tail_lines=100)

            Tool result: "Starting memory leak simulation...
            Allocated 1MB so far ... Allocated 47MB so far
            Killed"

            Analysis: Pod broken-api-7d4f-abc has OOMKilled 5 times. Logs confirm
            memory allocation loop hitting the 60Mi limit. Root cause: unbounded
            memory growth in the application code.

            Calling tool: restart_pod(pod_name="broken-api-7d4f-abc")

            Tool result: SUCCESS: Pod deleted. K8s will recreate it.

            == Cluster Health Summary ==
            - 1 pod failing: broken-api (OOMKilled x5)
            - 1 pod healthy: devops-agent

            == Root Cause ==
            broken-api: Memory leak — allocating 1MB/iteration with no cleanup.
            Container limit 60Mi exhausted in ~30s.

            == Actions Taken ==
            - Restarted pod: broken-api-7d4f-abc

            == Recommendations ==
            - Increase memory limit to 256Mi as short-term relief
            - Fix the memory leak in application code (chunks list never cleared)
            - Add memory usage monitoring alert at 80% of limit
            ```
        5. Verify the agent's actions worked
            ```
            # Pod was restarted — you should see a new pod (AGE will be very young)
            kubectl get pods

            # Watch it OOMKill again (it will — root cause is still the app code)
            # That's expected! The agent correctly identified the fix is in the app code.
            kubectl get pods -w

            # Clean up when done testing
            kubectl delete -f k8s/broken-app.yaml
            kubectl delete -f k8s/rbac.yaml
            ``` 

    * kind vs EKS cheatsheet   

        - Cluster lifecycle   
            ```
            # CREATE CLUSTER
            kind create cluster                          # kind
            terraform apply                              # EKS (+ aws eks update-kubeconfig)

            # DELETE CLUSTER
            kind delete cluster                          # kind
            terraform destroy                            # EKS

            # POINT KUBECTL AT CLUSTER
            # (kind does this automatically)
            aws eks update-kubeconfig --region us-east-1 --name devops-agent  # EKS

            # LIST CONTEXTS
            kubectl config get-contexts                  # same for both

            # SWITCH CONTEXT
            kubectl config use-context kind-kind         # kind
            kubectl config use-context devops-eks        # EKS (after rename)
            ```

        - kubectl commands — 100% identical   
            ```
            # These work EXACTLY THE SAME on kind and EKS:
            kubectl apply -f manifest.yaml
            kubectl get pods -w
            kubectl get nodes
            kubectl describe pod <name>
            kubectl logs <name> --tail=50 --previous
            kubectl exec -it <name> -- bash
            kubectl delete pod <name>
            kubectl rollout status deployment/<name>
            kubectl scale deployment <name> --replicas=3
            kubectl get events --sort-by=.lastTimestamp
            kubectl port-forward svc/<name> 8080:8080
            ```   

        - Images — the only real difference   
            ```
            # kind: load image directly from local Docker
            kind load docker-image my-app:latest

            # EKS: push to ECR, then reference in YAML
            docker build --platform linux/amd64 -t $ECR_URL:latest .
            docker push $ECR_URL:latest
            # Then in yaml: image: 123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:latest

            # Why ECR instead of local?
            # EKS nodes are real EC2 instances in AWS — they can't see your laptop's Docker.
            # They pull images from a registry. ECR is the AWS-native registry (free tier included).
            ```   

        - RBAC and ServiceAccounts   
            ```
            # kind: permissive by default, RBAC optional for learning
            # EKS: RBAC enforced. Pods can't call K8s API without explicit permissions.
            # This is why we have rbac.yaml — identical YAML format to kind, just required.

            # EKS bonus: IRSA lets pods get AWS credentials automatically
            # No equivalent in kind (kind has no AWS IAM)

            # Check if a ServiceAccount has the IRSA annotation
            kubectl get sa devops-agent -o jsonpath='{.metadata.annotations}'
            # {"eks.amazonaws.com/role-arn":"arn:aws:iam::123:role/..."}
            ```
    </details>

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