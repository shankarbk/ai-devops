# =============================================================================
# Dockerfile — DevOps Agent
#
# WHY python:3.11-slim AND NOT a bedrock-agentcore base image?
#   The image public.ecr.aws/bedrock-agentcore/python:3.11 does NOT exist.
#   AgentCore Runtime's preferred deployment method is a .zip package, not
#   a container. For EKS deployment (our use case), we use standard
#   python:3.11-slim and install the bedrock-agentcore SDK ourselves.
#   This is also the lighter, more transparent option — you see exactly
#   what goes into the image.
#
# SIZE TARGET: ~350MB (slim base + only required packages)
# =============================================================================
# FROM public.ecr.aws/bedrock-agentcore/python:3.11
FROM python:3.11-slim

WORKDIR /app

# Install system dependencies needed by the kubernetes Python SDK
# and for building any C-extension wheels
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first — Docker layer caches this separately from code.
# Only invalidated when requirements.txt changes, not on every code edit.
COPY requirements.txt .

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# Copy agent source code
COPY agent/ ./agent/
COPY main.py .

# AgentCore SDK (and our HTTP server) listens on 8080
EXPOSE 8080

# Healthcheck so EKS knows when the container is ready
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/ping || exit 1

CMD ["python", "main.py"]
