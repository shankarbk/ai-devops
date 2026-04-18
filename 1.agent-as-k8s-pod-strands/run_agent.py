"""
run_agent.py — run the DevOps agent from your local machine

HOW THIS WORKS:
  - Uses ~/.kube/config (already pointing at EKS from 'aws eks update-kubeconfig')
  - Uses ~/.aws/credentials for Bedrock API calls
  - No Docker, no pod, no port-forward needed
  - Exact same agent code that runs inside EKS

USAGE:
  python run_agent.py                          # default: full diagnosis
  python run_agent.py "list all pods"          # custom prompt
  python run_agent.py "restart pod broken-api-xxx"
"""

import sys
import os

# Make sure Python can find the agent package
# (run this script from the project root where agent/ folder lives)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agent.agent import run_diagnosis

# Read prompt from command line arg, or use default
if len(sys.argv) > 1:
    prompt = " ".join(sys.argv[1:])
else:
    prompt = (
        "Diagnose all pods in the default namespace. "
        "Fix any pods that are failing. "
        "Provide a detailed report of findings and actions taken."
    )

print(f"\n{'='*60}")
print(f"Prompt: {prompt}")
print(f"{'='*60}\n")

result = run_diagnosis(prompt)
print(result)
