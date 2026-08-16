"""Provider secret-store tests (architecture §12, §5.3)."""

from __future__ import annotations

import pytest
from app import secrets as secrets_module
from app.main import app
from fastapi.testclient import TestClient

client = TestClient(app)


@pytest.fixture(autouse=True)
def reset_secret_store():
    """Each test starts with a fresh in-memory secret store."""
    secrets_module._secret_store = secrets_module.MemorySecretStore()
    yield
    secrets_module._secret_store = None


def _put(user_id: str, provider: str, api_key: str) -> dict:
    response = client.put(
        f"/api/v1/providers/{provider}/secret",
        headers={"X-User-Id": user_id},
        json={"api_key": api_key},
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_set_get_round_trip() -> None:
    _put("u1", "deepgram", "sk-deepgram-1")
    response = client.get(
        "/api/v1/providers/deepgram/secret", headers={"X-User-Id": "u1"}
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data == {"provider": "deepgram", "configured": True}
    # The key itself is never echoed back.
    assert "sk-deepgram-1" not in response.text


def test_secrets_are_user_scoped() -> None:
    _put("u1", "deepgram", "sk-u1")
    response = client.get(
        "/api/v1/providers/deepgram/secret", headers={"X-User-Id": "u2"}
    )
    assert response.json()["data"]["configured"] is False
    assert secrets_module.get_secret_store().get("u2", "deepgram") is None


def test_delete_removes_the_key() -> None:
    _put("u1", "openai", "sk-openai")
    response = client.delete(
        "/api/v1/providers/openai/secret", headers={"X-User-Id": "u1"}
    )
    assert response.json()["data"]["configured"] is False
    response = client.get(
        "/api/v1/providers/openai/secret", headers={"X-User-Id": "u1"}
    )
    assert response.json()["data"]["configured"] is False


def test_blank_key_rejected() -> None:
    response = client.put(
        "/api/v1/providers/openai/secret",
        headers={"X-User-Id": "u1"},
        json={"api_key": "   "},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


def test_missing_key_rejected_at_boundary() -> None:
    response = client.put(
        "/api/v1/providers/openai/secret",
        headers={"X-User-Id": "u1"},
        json={},
    )
    assert response.status_code == 422


def test_invalid_provider_name_rejected() -> None:
    response = client.put(
        "/api/v1/providers/bad%20name/secret",
        headers={"X-User-Id": "u1"},
        json={"api_key": "sk-x"},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "INVALID_REQUEST"


def test_normalize_provider() -> None:
    assert secrets_module.normalize_provider("  DeepGram ") == "deepgram"
    with pytest.raises(ValueError):
        secrets_module.normalize_provider("bad name")


def test_memory_store_round_trip() -> None:
    store = secrets_module.MemorySecretStore()
    store.set("u1", "openai", "sk-1")
    assert store.get("u1", "openai") == "sk-1"
    assert store.get("u2", "openai") is None
    store.delete("u1", "openai")
    assert store.get("u1", "openai") is None


def test_resolve_user_key_precedes_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DEEPGRAM_API_KEY", "sk-env")
    assert secrets_module.resolve_provider_key("u1", "deepgram") == "sk-env"
    store = secrets_module.get_secret_store()
    store.set("u1", "deepgram", "sk-user")
    assert secrets_module.resolve_provider_key("u1", "deepgram") == "sk-user"
    assert secrets_module.resolve_provider_key("u2", "deepgram") == "sk-env"
