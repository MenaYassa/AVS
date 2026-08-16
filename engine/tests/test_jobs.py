"""Job lifecycle API tests (architecture §7.1)."""

from __future__ import annotations

from app.main import app
from app.models import ErrorDetail, JobStatus
from app.store import get_store
from fastapi.testclient import TestClient

client = TestClient(app)


def _create_job(user_id: str = "u1", kind: str = "analyze") -> dict:
    response = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": user_id},
        json={"kind": kind, "input_ref": "audio-ref", "options": {"lang": "en"}},
    )
    assert response.status_code == 202
    return response.json()["data"]


def test_create_job_returns_202_envelope() -> None:
    job = _create_job()
    assert job["status"] == "queued"
    assert job["kind"] == "analyze"
    assert job["user_id"] == "u1"
    assert job["input_ref"] == "audio-ref"
    assert job["options"] == {"lang": "en"}


def test_create_rejects_unknown_kind() -> None:
    response = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": "u1"},
        json={"kind": "time_travel"},
    )
    # FastAPI/pydantic rejects invalid enums at the boundary (422).
    assert response.status_code == 422


def test_get_job_round_trip() -> None:
    job = _create_job()
    response = client.get(f"/api/v1/jobs/{job['id']}", headers={"X-User-Id": "u1"})
    assert response.status_code == 200
    assert response.json()["data"]["id"] == job["id"]


def test_get_job_is_user_scoped() -> None:
    job = _create_job(user_id="u1")
    response = client.get(f"/api/v1/jobs/{job['id']}", headers={"X-User-Id": "u2"})
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "JOB_ACCESS_DENIED"


def test_get_missing_job_is_404() -> None:
    response = client.get("/api/v1/jobs/nope", headers={"X-User-Id": "u1"})
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "JOB_NOT_FOUND"


def test_cancel_job() -> None:
    job = _create_job()
    response = client.post(
        f"/api/v1/jobs/{job['id']}/cancel", headers={"X-User-Id": "u1"}
    )
    assert response.status_code == 200
    assert response.json()["data"]["status"] == "cancelled"


def test_cancel_terminal_job_rejected() -> None:
    job = _create_job()
    client.post(f"/api/v1/jobs/{job['id']}/cancel", headers={"X-User-Id": "u1"})
    response = client.post(
        f"/api/v1/jobs/{job['id']}/cancel", headers={"X-User-Id": "u1"}
    )
    assert response.status_code == 400


def test_stream_returns_sse_events_until_terminal() -> None:
    job = _create_job()
    client.post(f"/api/v1/jobs/{job['id']}/cancel", headers={"X-User-Id": "u1"})
    with client.stream(
        "GET", f"/api/v1/jobs/{job['id']}/stream", headers={"X-User-Id": "u1"}
    ) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        events = "".join(response.iter_text())
    assert "event: job" in events
    assert "event: progress" in events
    assert "event: cancelled" in events
    assert "event: done" not in events


def test_stream_failed_job_emits_failed_event() -> None:
    job = _create_job()
    store = get_store()
    stored = store.get(job["id"])
    assert stored is not None
    store.update(
        stored.with_updated(
            status=JobStatus.failed,
            error=ErrorDetail(code="STAGE_RUNTIME", message="boom"),
        )
    )
    with client.stream(
        "GET", f"/api/v1/jobs/{job['id']}/stream", headers={"X-User-Id": "u1"}
    ) as response:
        assert response.status_code == 200
        events = "".join(response.iter_text())
    assert "event: failed" in events
    assert "STAGE_RUNTIME" in events


def test_job_response_embeds_session_lifecycle() -> None:
    job = _create_job()
    assert job["session_status"] == "uploading"
    response = client.get(f"/api/v1/jobs/{job['id']}", headers={"X-User-Id": "u1"})
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["session_status"] == "uploading"
    assert data["stage_label"] == "Transcribing"


def test_requires_auth_headers() -> None:
    response = client.post("/api/v1/jobs", json={"kind": "analyze"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "UNAUTHORIZED"
