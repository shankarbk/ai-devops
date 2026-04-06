import boto3
import json

# boto3 client for Bedrock AgentCore (uses bedrock-agentcore service)
client = boto3.client("bedrock-agentcore", region_name="us-east-1")

ACCOUNT_ID = boto3.client("sts").get_caller_identity()["Account"]
ECR_IMAGE = f"{ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/devops-agent:latest"

# Agent role that AgentCore will assume when running your container
# It needs: ecr:GetAuthorizationToken, ecr:BatchGetImage (to pull image)
# AND your agent's IAM permissions (Bedrock invoke, etc.)
EXECUTION_ROLE_ARN = f"arn:aws:iam::{ACCOUNT_ID}:role/devops-agent-eks-agent-role"

response = client.create_agent_runtime(
    agentRuntimeName="devops-k8s-agent",
    description="Autonomous Kubernetes diagnostic and remediation agent",
    
    agentRuntimeArtifact={
        "containerConfiguration": {
            "containerUri": ECR_IMAGE
        }
    },
    
    roleArn=EXECUTION_ROLE_ARN,
    
    # Network config: VPC mode so the agent can reach EKS API server
    networkConfiguration={
        "networkMode": "VPC",
    },
    
    # Auth: Bedrock agents support IAM auth — callers need
    # bedrock:InvokeAgentRuntime permission
    authorizerConfiguration={
        "customJWTAuthorizer": {
            "allowedAudience": ["bedrock-agentcore"],
            "allowedClients": [ACCOUNT_ID],
        }
    }
)

agent_arn = response["agentRuntimeArn"]
print(f"Agent created: {agent_arn}")
print("Test invocation:")
print(f"  python invoke_agent.py --agent-arn {agent_arn}")