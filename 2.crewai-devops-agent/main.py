"""
main.py — HTTP server wrapping the CrewAI crew

WHY THIS IS IDENTICAL TO THE STRANDS VERSION:
  The BedrockAgentCoreApp wrapper doesn't care what framework
  powers your agent. It just wraps any Python function in an
  HTTP server with /invocations and /ping endpoints.

  Strands version:   handler calls strands_agent(prompt)
  CrewAI version:    handler calls crew.kickoff(inputs={...})
  Same interface, different internals.
"""

from bedrock_agentcore import BedrockAgentCoreApp
from agent.crew import run_diagnosis

app = BedrockAgentCoreApp()


@app.entrypoint
def handler(payload: dict) -> str:
    """
    Called on every POST /invocations.
    Accepts: {"input_text": "...", "namespace": "..."}
    """
    namespace = payload.get("namespace", "default")
    message   = payload.get("input_text") or payload.get("prompt", "")

    if not message:
        return "Error: request body must include 'input_text' or 'prompt'."

    # Run the full CrewAI diagnosis + remediation workflow
    return run_diagnosis(namespace=namespace)


if __name__ == "__main__":
    app.run()
