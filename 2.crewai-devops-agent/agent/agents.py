"""
agent/agents.py — CrewAI Agent definitions

THE BIG ARCHITECTURAL DIFFERENCE FROM STRANDS:

  Strands:  ONE agent that does everything. It has all 4 tools and the
            LLM figures out what to do in a single ReAct loop.

  CrewAI:   MULTIPLE specialized agents, each with a specific ROLE, GOAL,
            and BACKSTORY. Each agent only gets the tools relevant to its job.
            They collaborate through tasks (see crew.py).

WHY THIS MATTERS:
  The SRE Analyst diagnoses — it reads pods and logs.
  The Remediation Engineer fixes — it restarts pods and scales deployments.
  Neither agent can accidentally do the other's job.
  This is cleaner separation of concerns for production use.

HOW CrewAI CONNECTS TO BEDROCK:
  CrewAI uses LiteLLM under the hood for LLM calls.
  The model string format is: "bedrock/<model_id>"
  LiteLLM handles the boto3 call to Bedrock automatically.
  Your AWS credentials (IRSA in EKS, or ~/.aws/credentials locally)
  are picked up by boto3 the same way as before.
"""

import os
from crewai import Agent, LLM
from agent.tools import get_pods_status, get_pod_logs, restart_pod, scale_deployment

# ── LLM Configuration ─────────────────────────────────────────────────────
# CrewAI uses LiteLLM which uses the "bedrock/" prefix to route to Bedrock.
# No API key needed — boto3 picks up IRSA credentials automatically in EKS,
# or ~/.aws/credentials on your laptop.
#
# Model string format: "bedrock/anthropic.claude-3-haiku-20240307-v1:0"
# Same Haiku model as before — cheapest, fast enough for log analysis.

BEDROCK_MODEL = os.getenv(
    "BEDROCK_MODEL_ID",
    "bedrock/anthropic.claude-3-haiku-20240307-v1:0",
)
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

llm = LLM(
    model=BEDROCK_MODEL,
    # LiteLLM passes these to boto3 as session kwargs
    aws_region_name=AWS_REGION,
    temperature=0.1,      # low temperature = consistent, deterministic decisions
    max_tokens=2048,
)


# ── Agent 1: SRE Analyst ───────────────────────────────────────────────────
# This agent ONLY observes — it reads pod status and logs.
# It has NO remediation tools, so it cannot accidentally restart things.
#
# role:      Short label used in task assignments and output headers
# goal:      What this agent is trying to achieve — guides its reasoning
# backstory: Context that shapes HOW the agent reasons about its role
# tools:     Only observation tools — no restart, no scale

sre_analyst = Agent(
    role="Senior SRE Analyst",
    goal=(
        "Accurately diagnose the health of every pod in the Kubernetes cluster. "
        "Identify root causes of failures using pod status and log analysis. "
        "Produce a structured diagnosis report that the remediation engineer can act on."
    ),
    backstory=(
        "You are a Senior Site Reliability Engineer with 10 years of Kubernetes experience. "
        "You have deep expertise in diagnosing container failures: OOMKilled events, "
        "CrashLoopBackOff patterns, ImagePullBackOff errors, and resource exhaustion. "
        "You are methodical — you always check pod status first, then fetch logs for "
        "any unhealthy pods before drawing conclusions. You never guess; you read the evidence."
    ),
    tools=[get_pods_status, get_pod_logs],
    llm=llm,
    verbose=True,           # prints reasoning steps — great for learning
    max_iter=10,            # max tool-call iterations before giving up
    allow_delegation=False, # this agent doesn't hand off to others
)


# ── Agent 2: Remediation Engineer ─────────────────────────────────────────
# This agent ONLY acts — it restarts pods and scales deployments.
# It receives the diagnosis from the SRE Analyst as context.
# It has NO observation tools — it doesn't re-read logs itself.
#
# WHY SEPARATE AGENTS?
#   Cleaner audit trail: you can see exactly what each agent decided.
#   Safer: the analyst can't accidentally trigger a restart.
#   Testable: you can test diagnosis and remediation independently.

remediation_engineer = Agent(
    role="Kubernetes Remediation Engineer",
    goal=(
        "Execute safe and targeted remediation actions on failing Kubernetes workloads. "
        "Restart pods that are stuck in failure states. Scale deployments when resource "
        "exhaustion is confirmed. Never act on healthy pods. Always explain actions taken."
    ),
    backstory=(
        "You are a Kubernetes operations engineer specializing in incident response. "
        "You receive structured diagnosis reports and execute precise remediation actions. "
        "Your rules are strict: you ONLY restart pods confirmed as OOMKilled or in "
        "CrashLoopBackOff. You ONLY scale deployments when memory exhaustion is the "
        "confirmed root cause. You document every action you take with a clear justification."
    ),
    tools=[restart_pod, scale_deployment],
    llm=llm,
    verbose=True,
    max_iter=8,
    allow_delegation=False,
)
