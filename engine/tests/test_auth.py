"""Auth tests (dev mode; production JWKS path is exercised in CI/integration)."""

from __future__ import annotations

import jwt as pyjwt
from app.main import app
from fastapi.testclient import TestClient

client = TestClient(app)


def _signed_dev_token(user_id: str) -> str:
    return pyjwt.encode({"sub": user_id}, "dev-secret", algorithm="HS256")


def test_bearer_token_sub_becomes_user_id() -> None:
    token = _signed_dev_token("u-xyz")
    response = client.get(
        "/api/v1/jobs/nope", headers={"Authorization": f"Bearer {token}"}
    )
    # Auth resolves to u-xyz; the job simply doesn't exist (404, not 401).
    assert response.status_code == 404


def test_dev_user_id_header() -> None:
    response = client.get("/api/v1/jobs/nope", headers={"X-User-Id": "u1"})
    assert response.status_code == 404


def test_missing_credentials_are_rejected() -> None:
    response = client.get("/api/v1/jobs/nope")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


def test_invalid_bearer_is_rejected() -> None:
    response = client.get(
        "/api/v1/jobs/nope", headers={"Authorization": "Bearer not-a-jwt"}
    )
    assert response.status_code == 401
