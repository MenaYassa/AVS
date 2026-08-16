"""Shared pytest fixtures."""

from __future__ import annotations

import pytest
from app import store as store_module
from app.store import MemoryJobStore


@pytest.fixture(autouse=True)
def reset_job_store():
    """Each test starts with a fresh in-memory job store."""
    store_module._store = MemoryJobStore()
    yield
    store_module._store = None
