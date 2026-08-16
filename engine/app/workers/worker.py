"""Orchestrator worker entrypoint (architecture §4.2, §9.2)."""

from __future__ import annotations

from app.workers.orchestrator import start_worker

if __name__ == "__main__":
    start_worker()
