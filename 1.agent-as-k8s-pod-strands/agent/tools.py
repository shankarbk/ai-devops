# Doc link : https://github.com/kubernetes-client/python/blob/master/kubernetes/README.md
import subprocess
import json
from strands import tool
from typing import Optional
from kubernetes import client, config
from .config import DEFAULT_NAMESPACE

# Load kubeconfig — works locally AND in-cluster (EKS pod)
# kubernetes library auto-detects: if KUBERNETES_SERVICE_HOST env
# var exists, uses in-cluster config; otherwise uses ~/.kube/config
try:
    config.load_incluster_config()   # running inside EKS pod
except:
    config.load_kube_config()         # local dev machine

v1 = client.CoreV1Api()
apps_v1 = client.AppsV1Api()


@tool
def get_pod_logs(
    pod_name: str,
    namespace: str = DEFAULT_NAMESPACE,
    tail_lines: int = 100
) -> str:
    """
    Fetch the last N lines of logs from a Kubernetes pod.
    Use this to diagnose application errors, crashes, and
    OOMKilled events. Returns raw log text.
    
    Args:
        pod_name: Name of the pod (e.g. 'api-server-7d9f8b-xyz')
        namespace: K8s namespace (default: 'default')
        tail_lines: How many log lines to return (default: 100)
    """
    try:
        logs = v1.read_namespaced_pod_log(
            name=pod_name,
            namespace=namespace,
            tail_lines=tail_lines,
            timestamps=True   # include timestamps for diagnosis
        )
        return logs if logs else "[No logs found — pod may not have started]"
    except Exception as e:
        return f"ERROR fetching logs for {pod_name}: {str(e)}"


@tool
def get_pods_status(
    namespace: str = DEFAULT_NAMESPACE
) -> str:
    """
    List all pods in a namespace with their current status,
    restart count, and age. Use this as the first step in any
    diagnosis to identify which pods are unhealthy.
    
    Returns JSON string with pod name, phase, restarts, conditions.
    """
    try:
        pods = v1.list_namespaced_pod(namespace=namespace)
        result = []
        for pod in pods.items:
            container_statuses = pod.status.container_statuses or []
            restarts = sum(cs.restart_count for cs in container_statuses)
            
            # Extract reason for any terminated containers (OOMKilled, Error)
            reasons = []
            for cs in container_statuses:
                if cs.last_state.terminated:
                    reasons.append(cs.last_state.terminated.reason)
            
            result.append({
                "name": pod.metadata.name,
                "phase": pod.status.phase,
                "restart_count": restarts,
                "last_termination_reason": reasons,
                "conditions": [
                    {"type": c.type, "status": c.status}
                    for c in (pod.status.conditions or [])
                ]
            })
        return json.dumps(result, indent=2)
    except Exception as e:
        return f"ERROR listing pods: {str(e)}"


@tool
def restart_pod(
    pod_name: str,
    namespace: str = DEFAULT_NAMESPACE
) -> str:
    """
    Restart a pod by deleting it. Kubernetes will automatically
    recreate it from its ReplicaSet/Deployment. Use this for
    pods stuck in CrashLoopBackOff, OOMKilled, or Error state.
    
    IMPORTANT: Only use this after confirming the pod is unhealthy.
    Do NOT restart pods that are Running and Healthy.
    """
    try:
        # Deleting a pod managed by a Deployment is safe —
        # the ReplicaSet controller immediately creates a new one
        v1.delete_namespaced_pod(
            name=pod_name,
            namespace=namespace,
            body=client.V1DeleteOptions(grace_period_seconds=0)
        )
        return f"SUCCESS: Pod '{pod_name}' deleted. K8s will recreate it. Monitor with get_pods_status."
    except Exception as e:
        return f"ERROR restarting pod {pod_name}: {str(e)}"


@tool
def scale_deployment(
    deployment_name: str,
    replicas: int,
    namespace: str = DEFAULT_NAMESPACE
) -> str:
    """
    Scale a Kubernetes Deployment to the specified replica count.
    Use this to handle high load (scale up) or reduce resource
    usage (scale down). Replicas must be between 1 and 10.
    
    Args:
        deployment_name: Name of the Deployment resource
        replicas: Target replica count (1-10)
    """
    if not (1 <= replicas <= 10):
        return "ERROR: replicas must be between 1 and 10. Refusing to scale."
    
    try:
        # patch_namespaced_deployment_scale updates only the .spec.replicas field
        # without touching the rest of the deployment — the safest way to scale
        apps_v1.patch_namespaced_deployment_scale(
            name=deployment_name,
            namespace=namespace,
            body={"spec": {"replicas": replicas}}
        )
        return f"SUCCESS: Deployment '{deployment_name}' scaled to {replicas} replicas."
    except Exception as e:
        return f"ERROR scaling {deployment_name}: {str(e)}"