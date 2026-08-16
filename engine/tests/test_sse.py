"""SSE progress stream tests (architecture §7.1, §4.5)."""

from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any, AsyncIterator

import pytest
from app.models import ErrorDetail, Job, JobKind, JobStatus
from app.sse import stream_job_status
from app.stages.names import STAGE_CLEANUP, STAGE_VALIDATION


def _job(
    *,
    status: JobStatus,
    stage: str | None = None,
    kind: JobKind = JobKind.analyze,
) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id="j1",
        user_id="u1",
        kind=kind,
        status=status,
        stage=stage,
        error=(
            ErrorDetail(code="STAGE_RUNTIME", message="boom")
            if status is JobStatus.failed
            else None
        ),
        created_at=now,
        updated_at=now,
    )


def _parse_event(event: str) -> tuple[str, dict[str, Any]]:
    name = ""
    data: dict[str, Any] = {}
    for line in event.split("\n"):
        if line.startswith("event: "):
            name = line[len("event: ") :]
        elif line.startswith("data: "):
            data = json.loads(line[len("data: ") :])
    return name, data


async def _collect(stream: AsyncIterator[str]) -> list[tuple[str, dict[str, Any]]]:
    return [_parse_event(event) async for event in stream]


@pytest.mark.asyncio
async def test_progress_events_track_lifecycle_until_done() -> None:
    sequence: list[Job] = [
        _job(status=JobStatus.running, stage=None),
        _job(status=JobStatus.running, stage=STAGE_CLEANUP),
        _job(status=JobStatus.running, stage=STAGE_VALIDATION),
        _job(status=JobStatus.succeeded, stage=None),
    ]
    index = 0

    def get_job(_: str) -> Job:
        nonlocal index
        job = sequence[min(index, len(sequence) - 1)]
        index += 1
        return job

    events = await _collect(stream_job_status("j1", get_job, poll_seconds=0.0))

    progress = [data for name, data in events if name == "progress"]
    statuses = [p["session_status"] for p in progress]
    assert statuses == ["transcribing", "cleaning", "validating", "ready"]

    done = [data for name, data in events if name == "done"]
    assert len(done) == 1
    assert done[0]["session_status"] == "ready"


@pytest.mark.asyncio
async def test_failed_terminal_event() -> None:
    def get_job(_: str) -> Job:
        return _job(status=JobStatus.failed, stage=STAGE_CLEANUP)

    events = await _collect(stream_job_status("j1", get_job, poll_seconds=0.0))
    names = [name for name, _ in events]
    assert "failed" in names
    assert "done" not in names
    failed = [data for name, data in events if name == "failed"][0]
    assert failed["session_status"] == "failed"
    assert failed["error"]["code"] == "STAGE_RUNTIME"


@pytest.mark.asyncio
async def test_cancelled_terminal_event() -> None:
    def get_job(_: str) -> Job:
        return _job(status=JobStatus.cancelled)

    events = await _collect(stream_job_status("j1", get_job, poll_seconds=0.0))
    names = [name for name, _ in events]
    assert "cancelled" in names
    assert "done" not in names
    cancelled = [data for name, data in events if name == "cancelled"][0]
    assert cancelled["session_status"] == "cancelled"


@pytest.mark.asyncio
async def test_non_analyze_job_progress_has_null_session() -> None:
    sequence = [
        _job(status=JobStatus.running, kind=JobKind.rewrite),
        _job(status=JobStatus.succeeded, kind=JobKind.rewrite),
    ]
    index = 0

    def get_job(_: str) -> Job:
        nonlocal index
        job = sequence[min(index, len(sequence) - 1)]
        index += 1
        return job

    events = await _collect(
        stream_job_status("j1", get_job, poll_seconds=0.0, idle_seconds=0.1)
    )
    progress = [data for name, data in events if name == "progress"]
    assert progress
    assert all(p["session_status"] is None for p in progress)


@pytest.mark.asyncio
async def test_job_events_emitted_per_stage_change() -> None:
    sequence: list[Job] = [
        _job(status=JobStatus.running, stage=None),
        _job(status=JobStatus.running, stage=STAGE_CLEANUP),
        _job(status=JobStatus.succeeded, stage=None),
    ]
    index = 0

    def get_job(_: str) -> Job:
        nonlocal index
        job = sequence[min(index, len(sequence) - 1)]
        index += 1
        return job

    events = await _collect(stream_job_status("j1", get_job, poll_seconds=0.0))
    job_events = [data for name, data in events if name == "job"]
    stages = [j.get("stage") for j in job_events]
    assert stages == [None, STAGE_CLEANUP, None]
