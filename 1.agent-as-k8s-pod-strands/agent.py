from strands import Agent
from strands.models.bedrock import BedrockModel
from .tools import get_pod_logs, get_pods_status, restart_pod, scale_deployment
from .prompts import SYSTEM_PROMPT
from .config import AWS_REGION, MODEL_ID


def create_agent() -> Agent:
    """
    Factory function that creates and returns a configured DevOps agent.
    We use a factory so tests can call this without side effects.
    """
    
    # BedrockModel wraps boto3 bedrock-runtime client.
    # claude-3-haiku is cheapest ($0.00025/1K input tokens) and
    # fast enough for log analysis. Switch to sonnet for complex reasoning.
    model = BedrockModel(
        model_id=MODEL_ID,        # "anthropic.claude-3-haiku-20240307-v1:0"
        region_name=AWS_REGION,   # "us-east-1" for Free Tier
        max_tokens=2048,
        temperature=0.1,          # low temp = deterministic remediation decisions
    )
    
    agent = Agent(
        model=model,
        tools=[
            get_pod_logs,
            get_pods_status,
            restart_pod,
            scale_deployment,
        ],
        system_prompt=SYSTEM_PROMPT,
    )
    
    return agent


# Singleton for use in production (AgentCore will call this module)
devops_agent = create_agent()


def run_diagnosis(user_request: str) -> str:
    """Entry point called by AgentCore or CLI."""
    response = devops_agent(user_request)
    return str(response)