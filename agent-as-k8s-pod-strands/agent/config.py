import os

# Use env vars so the same code works locally, in Docker, and on EKS
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

# Haiku = cheapest, fastest. Change to sonnet for harder reasoning.
MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")

# K8s namespace the agent is allowed to operate in
# NEVER default to kube-system
DEFAULT_NAMESPACE = os.getenv("K8S_NAMESPACE", "default")