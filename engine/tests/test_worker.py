"""Worker/orchestrator tests: job lifecycle transitions (architecture §4.2
resumability). Unsupported/undermodelled jobs fail with a structured,
resumable error."""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from app.models import Job, JobKind, JobStatus
from app.store import get_store
from app.workers.orchestrator import process_job


def _queued_job(kind: JobKind = JobKind.transcribe) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=kind,
        status=JobStatus.queued,
        input_ref="audio-ref",
        created_at=now,
        updated_at=now,
    )


def test_process_job_rejects_non_analyze_kind_structurally() -> None:
    store = get_store()
    job = store.create(_queued_job())

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "UNSUPPORTED_JOB_KIND"
    assert updated.error.details == {"kind": "transcribe"}


def test_process_job_fails_missing_input_structurally() -> None:
    store = get_store()
    job = store.create(
        _queued_job(kind=JobKind.analyze).with_updated(input_ref=None)
    )

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "INPUT_INVALID"


def test_resume_reverts_failed_job_to_queued() -> None:
    from app.main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    created = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": "u1"},
        json={"kind": "analyze"},
    ).json()["data"]
    job_id = created["id"]

    process_job(job_id)
    assert (
        client.get(f"/api/v1/jobs/{job_id}", headers={"X-User-Id": "u1"}).json()[
            "data"
        ]["status"]
        == "failed"
    )

    resumed = client.post(f"/api/v1/jobs/{job_id}/resume", headers={"X-User-Id": "u1"})
    assert resumed.status_code == 200
    assert resumed.json()["data"]["status"] == "queued"
    assert resumed.json()["data"].get("error") is None
