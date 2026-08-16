"""Job lifecycle endpoints (architecture §7.1).

- POST /api/v1/jobs          -> 202 { job_id }
- GET  /api/v1/jobs/{id}     -> status + result
- POST /api/v1/jobs/{id}/cancel
- GET  /api/v1/jobs/{id}/stream  (SSE)
- POST /api/v1/jobs/{id}/resume  (failed jobs resume from last completed stage)
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

from fastapi import APIRouter, Depends, Request
from fastapi.responses import StreamingResponse

from app.auth import authenticate
from app.errors import (
    InvalidRequestError,
    JobAccessDeniedError,
    JobNotFoundError,
)
from app.lifecycle import job_payload
from app.models import Envelope, Job, JobCreateRequest, JobStatus
from app.queue import enqueue
from app.sse import stream_job_status
from app.store import get_store

router = APIRouter(prefix="/api/v1", tags=["jobs"])


async def _current_user(request: Request) -> str:
    return await authenticate(request)


def _envelope(job: Job) -> Envelope:
    return Envelope(data=job_payload(job))


@router.post("/jobs", status_code=202, response_model_exclude_none=True)
async def create_job(
    body: JobCreateRequest,
    user_id: str = Depends(_current_user),
) -> Envelope:
    now = datetime.now(timezone.utc)
    job = Job(
        id=str(uuid4()),
        user_id=user_id,
        kind=body.kind,
        status=JobStatus.queued,
        stage=None,
        input_ref=body.input_ref,
        options=body.options,
        prompt_versions=body.prompt_versions,
        created_at=now,
        updated_at=now,
    )
    job.validate_schema()
    get_store().create(job)
    enqueue(job)
    return _envelope(job)


@router.get("/jobs/{job_id}", response_model_exclude_none=True)
async def get_job(job_id: str, user_id: str = Depends(_current_user)) -> Envelope:
    job = get_store().get(job_id)
    if job is None:
        raise JobNotFoundError(f"No job {job_id}")
    if job.user_id != user_id:
        raise JobAccessDeniedError("Job does not belong to this user")
    return _envelope(job)


@router.post("/jobs/{job_id}/cancel", response_model_exclude_none=True)
async def cancel_job(job_id: str, user_id: str = Depends(_current_user)) -> Envelope:
    store = get_store()
    job = store.get(job_id)
    if job is None:
        raise JobNotFoundError(f"No job {job_id}")
    if job.user_id != user_id:
        raise JobAccessDeniedError("Job does not belong to this user")
    if job.status.terminal:
        raise InvalidRequestError(f"Cannot cancel a job in state {job.status.value}")
    cancelled = job.with_updated(status=JobStatus.cancelled)
    store.update(cancelled)
    return _envelope(cancelled)


@router.post("/jobs/{job_id}/resume", response_model_exclude_none=True)
async def resume_job(job_id: str, user_id: str = Depends(_current_user)) -> Envelope:
    store = get_store()
    job = store.get(job_id)
    if job is None:
        raise JobNotFoundError(f"No job {job_id}")
    if job.user_id != user_id:
        raise JobAccessDeniedError("Job does not belong to this user")
    if job.status != JobStatus.failed:
        raise InvalidRequestError("Only failed jobs can be resumed")
    resumed = job.with_updated(
        status=JobStatus.queued,
        error=None,
        stage=job.stage,  # resumes from last completed stage (Phase 2)
    )
    store.update(resumed)
    enqueue(resumed)
    return _envelope(resumed)


@router.get("/jobs/{job_id}/stream")
async def stream_job(
    job_id: str, request: Request, user_id: str = Depends(_current_user)
) -> StreamingResponse:
    store = get_store()
    job = store.get(job_id)
    if job is None:
        raise JobNotFoundError(f"No job {job_id}")
    if job.user_id != user_id:
        raise JobAccessDeniedError("Job does not belong to this user")

    async def event_stream():
        async for event in stream_job_status(job_id, store.get):
            if await request.is_disconnected():
                break
            yield event

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
