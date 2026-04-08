import pytest
from unittest.mock import patch, MagicMock
import json

# We patch the kubernetes client BEFORE importing tools
# so the module-level client.CoreV1Api() doesn't fail
with patch('kubernetes.config.load_kube_config'), \
     patch('kubernetes.config.load_incluster_config'):
    from agent.tools import get_pods_status, restart_pod, scale_deployment


def make_mock_pod(name, phase, restarts, last_reason=None):
    """Helper to create a fake V1Pod object."""
    pod = MagicMock()
    pod.metadata.name = name
    pod.status.phase = phase
    
    cs = MagicMock()
    cs.restart_count = restarts
    if last_reason:
        cs.last_state.terminated.reason = last_reason
    else:
        cs.last_state.terminated = None
    pod.status.container_statuses = [cs]
    pod.status.conditions = []
    return pod


@patch('agent.tools.v1')
def test_get_pods_status_detects_oomkilled(mock_v1):
    """Agent should detect OOMKilled in pod status."""
    mock_v1.list_namespaced_pod.return_value.items = [
        make_mock_pod("api-server-abc", "Failed", 5, "OOMKilled"),
        make_mock_pod("worker-xyz", "Running", 0),
    ]
    
    result = json.loads(get_pods_status("default"))
    
    oom_pod = next(p for p in result if p["name"] == "api-server-abc")
    assert "OOMKilled" in oom_pod["last_termination_reason"]
    assert oom_pod["restart_count"] == 5


@patch('agent.tools.v1')
def test_restart_pod_calls_delete(mock_v1):
    """restart_pod should call delete_namespaced_pod."""
    result = restart_pod("api-server-abc", "default")
    
    mock_v1.delete_namespaced_pod.assert_called_once_with(
        name="api-server-abc",
        namespace="default",
        body=MagicMock()
    )
    assert "SUCCESS" in result


@patch('agent.tools.apps_v1')
def test_scale_rejects_invalid_replicas(mock_apps_v1):
    """scale_deployment should refuse replicas outside 1-10."""
    result = scale_deployment("api-server", 0)
    assert "ERROR" in result
    mock_apps_v1.patch_namespaced_deployment_scale.assert_not_called()

    result = scale_deployment("api-server", 11)
    assert "ERROR" in result