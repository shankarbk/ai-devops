"""
agent/tasks.py — CrewAI Task definitions

WHAT IS A TASK IN CREWAI?
  A Task is a specific piece of work assigned to an Agent.
  It has:
    description:     What the agent should do (can include {variables})
    expected_output: What a good result looks like — guides the LLM's output format
    agent:           Which agent is responsible for this task
    context:         OTHER tasks whose output this task should use as input

TASK CHAINING:
  Task 1 (diagnosis)  → Task 2 (remediation, context=[task1])
  The remediation task automatically receives the diagnosis output as context.
  This is how CrewAI passes information between agents.

WHY NOT JUST ONE BIG TASK?
  Separate tasks = separate outputs you can inspect independently.
  If diagnosis is wrong, you can fix it without touching remediation logic.
  Each task has its own expected_output, which shapes LLM response format.
"""

from crewai import Task
from agent.agents import sre_analyst, remediation_engineer


# ── Task 1: Cluster Diagnosis ──────────────────────────────────────────────
# Assigned to: sre_analyst
# Tools available: get_pods_status, get_pod_logs
# Output: structured diagnosis report
#
# The {namespace} placeholder is filled in at runtime when you call crew.kickoff()
# with inputs={"namespace": "default"}

diagnosis_task = Task(
    description=(
        "Perform a complete health diagnosis of all pods in the '{namespace}' namespace.\n\n"
        "Follow this exact protocol:\n"
        "1. Call get_pods_status to get the current state of all pods\n"
        "2. For ANY pod that is NOT in 'Running' phase OR has restart_count > 3:\n"
        "   - Call get_pod_logs to read its recent logs\n"
        "   - Identify the root cause from the logs\n"
        "3. Classify each unhealthy pod with one of:\n"
        "   - OOMKilled: process exceeded memory limit\n"
        "   - CrashLoopBackOff: application error causing repeated crashes\n"
        "   - ImagePullBackOff: bad image tag or registry auth failure\n"
        "   - Pending: insufficient cluster resources\n"
        "4. For OOMKilled pods, note the memory usage pattern from logs\n\n"
        "Do NOT take any remediation actions — only diagnose."
    ),
    expected_output=(
        "A structured diagnosis report with these exact sections:\n"
        "## Cluster Health Summary\n"
        "- Total pods: X (Y healthy, Z failing)\n"
        "- List each failing pod with: name, phase, restart_count\n\n"
        "## Root Cause Analysis\n"
        "For each failing pod:\n"
        "- Pod name: <name>\n"
        "- Status: <phase>\n"
        "- Root cause: <OOMKilled|CrashLoopBackOff|ImagePullBackOff|Pending>\n"
        "- Evidence: <key log lines or event that confirms the diagnosis>\n"
        "- Recommended action: <restart|scale|fix image|investigate resources>\n\n"
        "## Pods Requiring No Action\n"
        "- List healthy pods with status Running"
    ),
    agent=sre_analyst,
)


# ── Task 2: Remediation ────────────────────────────────────────────────────
# Assigned to: remediation_engineer
# Tools available: restart_pod, scale_deployment
# context=[diagnosis_task] means this task automatically receives
# the full output of diagnosis_task as additional context before running.
#
# The engineer reads the diagnosis report and decides what actions to take.

remediation_task = Task(
    description=(
        "Review the diagnosis report from the SRE Analyst and execute safe remediation "
        "actions for all pods identified as requiring action in the '{namespace}' namespace.\n\n"
        "Remediation rules (follow strictly):\n"
        "- OOMKilled pod: call restart_pod. The pod needs a clean restart.\n"
        "- CrashLoopBackOff with > 5 restarts: call restart_pod.\n"
        "- OOMKilled AND restart_count > 3: restart_pod AND scale_deployment to 2 replicas\n"
        "  (distributes load, reduces per-pod memory pressure).\n"
        "- ImagePullBackOff: DO NOT restart. Report only — fix requires image tag correction.\n"
        "- Pending: DO NOT restart. Report only — fix requires cluster resource changes.\n"
        "- Running pods: DO NOT touch under any circumstances.\n\n"
        "For each action taken, state: what you did, why, and what to expect next."
    ),
    expected_output=(
        "A remediation report with these exact sections:\n"
        "## Actions Taken\n"
        "For each action:\n"
        "- Action: <restart_pod|scale_deployment|no_action>\n"
        "- Target: <pod_name or deployment_name>\n"
        "- Reason: <why this action was chosen based on the diagnosis>\n"
        "- Result: <SUCCESS or ERROR message from the tool>\n\n"
        "## Actions Not Taken (and why)\n"
        "- List any pods that needed human intervention instead\n\n"
        "## Expected Outcome\n"
        "- What should happen in the next 2-5 minutes after these actions"
    ),
    agent=remediation_engineer,
    context=[diagnosis_task],   # receives diagnosis_task output automatically
)
