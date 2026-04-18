# agent/__init__.py
# Exports run_diagnosis so callers can: from agent import run_diagnosis
from agent.crew import run_diagnosis

__all__ = ["run_diagnosis"]
