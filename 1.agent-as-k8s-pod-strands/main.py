# =============================================================================
# main.py — AgentCore entry point
#
# HOW BedrockAgentCoreApp WORKS:
#   The bedrock-agentcore SDK wraps your function in a Starlette ASGI app
#   that exposes two HTTP endpoints:
#     POST /invocations  — called by AgentCore Runtime (or our curl tests)
#     GET  /ping         — healthcheck, returns 200 OK
#
#   @app.entrypoint marks the function that handles each invocation.
#   The SDK passes the raw request body as a dict to your function.
# =============================================================================

from bedrock_agentcore import BedrockAgentCoreApp
from agent.agent import devops_agent

app = BedrockAgentCoreApp()


@app.entrypoint
def handler(payload: dict) -> str:
    """
    Called on every POST /invocations request.

    AgentCore and our curl tests both send JSON like:
        {"input_text": "Diagnose all pods in default namespace"}

    The Strands agent runs its tool-calling loop internally and
    returns the final text response as a string.
    """
    user_message = payload.get("input_text") or payload.get("prompt", "")

    if not user_message:
        return "Error: request body must contain 'input_text' or 'prompt' key."

    response = devops_agent(user_message)
    return str(response)


if __name__ == "__main__":
    # app.run() starts uvicorn on 0.0.0.0:8080
    # This is what runs inside the EKS pod / AgentCore Runtime container
    app.run()
