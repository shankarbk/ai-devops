"""
tests/test_tools.py — unit tests for the CrewAI agent tools

These tests mock the Kubernetes SDK so you don't need a live cluster.
Run: pytest tests/ -v
"""

import json
import pytest
from unittest.mock import patch, MagicMock

# Patch kubernetes config before importing tools
with patch("kubernetes.config.load_incluster_config"), \
     patch("kubernetes.config.load_kube_config"):
    from agent.tools import get_pods_status, restart_pod, scale_deployment


def make_mock_pod(name, phase, restarts, last_reason=None):
    pod = MagicMock()
    pod.metadata.name        = name
    pod.status.phase         = phase
    pod.status.conditions    = []
    cs = MagicMock()
    cs.restart_count         = restarts
    if last_reason:
        cs.last_state.terminated.reason = last_reason
    else:
        cs.last_state.terminated = None
    pod.status.container_statuses = [cs]
    return pod


@patch("agent.tools.v1")
def test_get_pods_status_detects_oomkilled(mock_v1):
    mock_v1.list_namespaced_pod.return_value.items = [
        make_mock_pod("broken-api-abc", "Failed", 5, "OOMKilled"),
        make_mock_pod("healthy-pod-xyz", "Running", 0),
    ]
    result = json.loads(get_pods_status("default"))
    broken = next(p for p in result if p["name"] == "broken-api-abc")
    assert broken["restart_count"] == 5
    assert "OOMKilled" in broken["last_termination_reason"]


@patch("agent.tools.v1")
def test_restart_pod_calls_delete(mock_v1):
    result = restart_pod("broken-api-abc", "default")
    mock_v1.delete_namespaced_pod.assert_called_once()
    assert "SUCCESS" in result


@patch("agent.tools.apps_v1")
def test_scale_rejects_zero_replicas(mock_apps):
    result = scale_deployment("my-app", 0)
    assert "REFUSED" in result
    mock_apps.patch_namespaced_deployment_scale.assert_not_called()


@patch("agent.tools.apps_v1")
def test_scale_rejects_too_many_replicas(mock_apps):
    result = scale_deployment("my-app", 11)
    assert "REFUSED" in result


@patch("agent.tools.apps_v1")
def test_scale_succeeds_for_valid_replicas(mock_apps):
    result = scale_deployment("my-app", 3, "default")
    mock_apps.patch_namespaced_deployment_scale.assert_called_once()
    assert "SUCCESS" in result
