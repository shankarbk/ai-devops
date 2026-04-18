"""
agent/crew.py — Crew definition and main entry point

WHAT IS A CREW?
  A Crew is the orchestrator. It takes:
    agents:  list of Agent objects
    tasks:   list of Task objects (order matters for sequential process)
    process: how tasks are executed

PROCESS TYPES:
  Process.sequential — tasks run one after another in order (our choice)
                        task2 gets task1's output as context automatically
  Process.hierarchical — a manager LLM decides which agent does what
                          more expensive, more autonomous, harder to debug

WHY SEQUENTIAL FOR THIS USE CASE?
  Diagnosis MUST happen before remediation. Sequential enforces this.
  Hierarchical would be overkill — we know the exact workflow we want.

ENTRY POINT:
  run_diagnosis(namespace) is the function called by:
    - run_agent.py (local testing)
    - main.py (HTTP server for EKS/AgentCore)
  Same interface as the Strands version — drop-in replacement.
"""

import os
from crewai import Crew, Process
from agent.agents import sre_analyst, remediation_engineer
from agent.tasks import diagnosis_task, remediation_task


def run_diagnosis(namespace: str = "default") -> str:
    """
    Run the full diagnosis + remediation workflow for a given namespace.

    Args:
        namespace: Kubernetes namespace to diagnose (default: 'default')

    Returns:
        Combined string output from both agents (diagnosis + remediation report)
    """

    # Create the Crew — wires agents and tasks together
    crew = Crew(
        agents=[sre_analyst, remediation_engineer],
        tasks=[diagnosis_task, remediation_task],

        # Sequential: diagnosis runs first, remediation gets its output as context
        process=Process.sequential,

        # verbose=True prints each agent's reasoning steps and tool calls to stdout
        # Set to False in production to reduce noise in pod logs
        verbose=bool(os.getenv("CREW_VERBOSE", "true").lower() == "true"),

        # memory=False: no cross-run memory (each call is independent)
        # Set memory=True + configure embedder if you want agents to remember
        # past diagnoses across multiple crew.kickoff() calls
        memory=False,
    )

    # kickoff() runs all tasks in order and returns the final task's output
    # inputs{} fills {namespace} placeholder in task descriptions
    result = crew.kickoff(inputs={"namespace": namespace})

    # result.raw is the plain string output from the last task
    # result.tasks_output is a list with each task's individual output
    # We return both joined so the caller sees the full picture
    full_output = ""
    for i, task_output in enumerate(result.tasks_output):
        task_name = ["DIAGNOSIS REPORT", "REMEDIATION REPORT"][i]
        full_output += f"\n{'='*60}\n{task_name}\n{'='*60}\n"
        full_output += task_output.raw + "\n"

    return full_output
