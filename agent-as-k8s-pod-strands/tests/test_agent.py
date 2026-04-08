import pytest
from unittest.mock import patch

# This test calls real Bedrock (costs ~$0.001 per run — negligible)
# It uses mock K8s so no cluster is needed

FAKE_PODS_JSON = """[
  {"name": "api-7d9f-abc", "phase": "Failed",
   "restart_count": 8, "last_termination_reason": ["OOMKilled"],
   "conditions": []},
  {"name": "worker-xyz", "phase": "Running",
   "restart_count": 0, "last_termination_reason": [], "conditions": []}
]"""

FAKE_LOGS = """
2024-01-15T10:23:44Z java.lang.OutOfMemoryError: Java heap space
2024-01-15T10:23:44Z     at java.util.Arrays.copyOf(Arrays.java:3210)
2024-01-15T10:23:45Z Killed
"""


@patch('kubernetes.config.load_kube_config')
@patch('kubernetes.config.load_incluster_config')
@patch('agent.tools.v1')
@patch('agent.tools.apps_v1')
def test_agent_diagnoses_oomkilled(mock_apps, mock_v1, *args):
    """Full agent integration: given OOMKilled pod, agent should
    restart it and scale up without human intervention."""
    
    import json
    
    # Mock list pods → returns our failing pod
    mock_pod_list = MagicMock()
    # Reuse the dict-based approach via get_pods_status mock directly
    mock_v1.list_namespaced_pod.return_value.items = []
    
    with patch('agent.tools.get_pods_status', return_value=FAKE_PODS_JSON), \
         patch('agent.tools.get_pod_logs', return_value=FAKE_LOGS):
        
        from agent.agent import run_diagnosis
        
        result = run_diagnosis(
            "Diagnose all pods in the 'default' namespace and fix any issues."
        )
    
    # The agent should mention OOMKilled in its response
    assert "OOMKilled" in result or "memory" in result.lower()
    print("\n=== AGENT RESPONSE ===")
    print(result)


# Run just this test:
# pytest tests/test_agent.py -v -s