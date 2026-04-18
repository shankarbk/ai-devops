"""
agent/tools.py — Kubernetes tools for the CrewAI DevOps agent

KEY DIFFERENCE FROM STRANDS:
  Strands uses: @tool decorator from strands package
  CrewAI uses:  @tool decorator from crewai.tools package

  The function signature and docstring style is the same concept,
  but CrewAI reads the docstring to describe the tool to the LLM,
  just like Strands does. Switching frameworks = change the import,
  keep your business logic identical.

IMPORTANT: CrewAI tools must have type-annotated arguments AND
  a clear single-line description as the first line of the docstring.
  CrewAI uses that first line as the tool's description in the prompt.
"""

import json
import os
from crewai.tools import tool
from kubernetes import client, config

# ── Kubernetes client setup ────────────────────────────────────────────────
# Identical to Strands version — the K8s SDK doesn't care which agent
# framework is calling it. Auto-detects in-cluster vs local kubeconfig.
try:
    config.load_incluster_config()   # running inside EKS pod
except Exception:
    config.load_kube_config()        # local dev machine

v1      = client.CoreV1Api()
apps_v1 = client.AppsV1Api()

DEFAULT_NAMESPACE = os.getenv("K8S_NAMESPACE", "default")


# ── Tool 1: List all pods with status ─────────────────────────────────────
@tool("get_pods_status")
def get_pods_status(namespace: str = DEFAULT_NAMESPACE) -> str:
    """
    List all pods in a Kubernetes namespace with status, restart count,
    and last termination reason. Use this as the FIRST step in any
    diagnosis to identify which pods are unhealthy.

    Args:
        namespace: Kubernetes namespace to inspect (default: 'default')

    Returns:
        JSON string with pod name, phase, restart_count, last_termination_reason
    """
    try:
        pods   = v1.list_namespaced_pod(namespace=namespace)
        result = []

        for pod in pods.items:
            container_statuses = pod.status.container_statuses or []
            total_restarts = sum(cs.restart_count for cs in container_statuses)

            # Extract termination reason (OOMKilled, Error, Completed, etc.)
            reasons = []
            for cs in container_statuses:
                if cs.last_state and cs.last_state.terminated:
                    reasons.append(cs.last_state.terminated.reason)

            result.append({
                "name":                    pod.metadata.name,
                "phase":                   pod.status.phase,
                "restart_count":           total_restarts,
                "last_termination_reason": reasons,
                "conditions": [
                    {"type": c.type, "status": c.status}
                    for c in (pod.status.conditions or [])
                ],
            })

        return json.dumps(result, indent=2)

    except Exception as e:
        return f"ERROR listing pods in namespace '{namespace}': {e}"


# ── Tool 2: Fetch pod logs ─────────────────────────────────────────────────
@tool("get_pod_logs")
def get_pod_logs(
    pod_name:   str,
    namespace:  str = DEFAULT_NAMESPACE,
    tail_lines: int = 100,
) -> str:
    """
    Fetch the last N log lines from a Kubernetes pod to diagnose errors.
    Use this after get_pods_status identifies a failing pod.

    Args:
        pod_name:   Exact pod name (e.g. 'broken-api-7d4f-abc12')
        namespace:  Kubernetes namespace (default: 'default')
        tail_lines: Number of recent log lines to return (default: 100)

    Returns:
        Raw log text with timestamps, or an error message
    """
    try:
        logs = v1.read_namespaced_pod_log(
            name=pod_name,
            namespace=namespace,
            tail_lines=tail_lines,
            timestamps=True,
        )
        return logs if logs else "[No logs — pod may not have started yet]"

    except Exception as e:
        return f"ERROR fetching logs for pod '{pod_name}': {e}"


# ── Tool 3: Restart a pod ──────────────────────────────────────────────────
@tool("restart_pod")
def restart_pod(pod_name: str, namespace: str = DEFAULT_NAMESPACE) -> str:
    """
    Restart a failing Kubernetes pod by deleting it. The ReplicaSet
    controller automatically recreates it. Use for OOMKilled or
    CrashLoopBackOff pods ONLY — never restart healthy Running pods.

    Args:
        pod_name:  Exact name of the pod to restart
        namespace: Kubernetes namespace (default: 'default')

    Returns:
        Success or error message
    """
    try:
        v1.delete_namespaced_pod(
            name=pod_name,
            namespace=namespace,
            body=client.V1DeleteOptions(grace_period_seconds=0),
        )
        return (
            f"SUCCESS: Pod '{pod_name}' deleted. "
            f"Kubernetes will recreate it automatically. "
            f"Call get_pods_status to verify the new pod comes up healthy."
        )
    except Exception as e:
        return f"ERROR restarting pod '{pod_name}': {e}"


# ── Tool 4: Scale a deployment ────────────────────────────────────────────
@tool("scale_deployment")
def scale_deployment(
    deployment_name: str,
    replicas:        int,
    namespace:       str = DEFAULT_NAMESPACE,
) -> str:
    """
    Scale a Kubernetes Deployment to a specified number of replicas.
    Use to handle high load (scale up) or reduce resource usage (scale down).
    Replicas must be between 1 and 10 — never scale to 0.

    Args:
        deployment_name: Name of the Deployment resource to scale
        replicas:        Target replica count (integer, 1 to 10)
        namespace:       Kubernetes namespace (default: 'default')

    Returns:
        Success or error message
    """
    if not (1 <= replicas <= 10):
        return (
            f"REFUSED: replicas={replicas} is outside the safe range 1–10. "
            f"Scaling not performed."
        )
    try:
        apps_v1.patch_namespaced_deployment_scale(
            name=deployment_name,
            namespace=namespace,
            body={"spec": {"replicas": replicas}},
        )
        return (
            f"SUCCESS: Deployment '{deployment_name}' scaled to "
            f"{replicas} replica(s) in namespace '{namespace}'."
        )
    except Exception as e:
        return f"ERROR scaling deployment '{deployment_name}': {e}"
