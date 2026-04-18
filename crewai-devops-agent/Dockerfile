# Dockerfile — CrewAI DevOps Agent
# Identical to Strands Dockerfile — only requirements.txt content differs.
# The container doesn't know or care which agent framework is inside.

FROM python:3.11-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc curl \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

COPY agent/ ./agent/
COPY main.py .
COPY run_agent.py .

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -f http://localhost:8080/ping || exit 1

# NOTE: CrewAI imports can take a few seconds longer than Strands on startup
# because it initialises LiteLLM. The startupProbe in agent-deployment.yaml
# gives 150s max — more than enough.
CMD ["python", "main.py"]
