"""
run_agent.py — run the CrewAI DevOps agent from your local machine

USAGE:
  python run_agent.py                     # diagnose 'default' namespace
  python run_agent.py --namespace prod    # diagnose 'prod' namespace
"""

import sys
import os
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agent.crew import run_diagnosis

parser = argparse.ArgumentParser(description="CrewAI DevOps Agent — local runner")
parser.add_argument(
    "--namespace", "-n",
    default="default",
    help="Kubernetes namespace to diagnose (default: 'default')",
)
args = parser.parse_args()

print(f"\n{'='*60}")
print(f"CrewAI DevOps Agent — diagnosing namespace: '{args.namespace}'")
print(f"{'='*60}\n")

result = run_diagnosis(namespace=args.namespace)
print(result)
