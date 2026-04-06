import boto3
import json
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--agent-arn", required=True)
parser.add_argument("--message", default="Diagnose all pods in default namespace")
args = parser.parse_args()

client = boto3.client("bedrock-agentcore-runtime", region_name="us-east-1")

# invoke_agent_runtime sends a request to your running agent
response = client.invoke_agent_runtime(
    agentRuntimeArn=args.agent_arn,
    qualifier="DEFAULT",
    sessionId="my-session-001",    # same session_id = conversation continuity
    payload=json.dumps({
        "input_text": args.message
    }).encode()
)

# AgentCore returns a streaming response — collect all chunks
full_response = ""
for event in response["response"]["stream"]:
    if "chunk" in event:
        full_response += event["chunk"]["bytes"].decode()

print(full_response)