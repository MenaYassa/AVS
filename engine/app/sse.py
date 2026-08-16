"""Server-Sent Events helpers (architecture §7.1).

Phase 2: the stream emits `job` records on every stage change plus `progress`
events carrying the session-lifecycle projection (`session_status` +
`stage_label`, §4.5) whenever it changes, and a typed terminal event
(`done` / `failed` / `cancelled`) so clients render a recoverable failure path.
"""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any, AsyncIterator

from app.lifecycle import derive_session_status, job_payload, stage_label
from app.models import Job, JobStatus


def format_sse(event: str, data: Any) -> str:
    return f"event: {event}\ndata: {json.dumps(data, default=str)}\n\n"


def _terminal_event(status: JobStatus) -> str:
    return {
        JobStatus.succeeded: "done",
        JobStatus.failed: "failed",
        JobStatus.cancelled: "cancelled",
    }.get(status, "done")


async def stream_job_status(
    job_id: str,
    get_job: Any,
    poll_seconds: float = 1.0,
    idle_seconds: float = 20.0,
) -> AsyncIterator[str]:
    """Yield SSE events until the job reaches a terminal state.

    - `job`: full job record (stage changes).
    - `progress`: `{session_status, stage, stage_label, job_status}` whenever
      the lifecycle projection changes.
    - `done` / `failed` / `cancelled`: terminal, includes the job record.
    """
    last_idle = time.monotonic()
    last_stage: str | None = None
    last_lifecycle: tuple[str, str | None, str] | None = None
    first = True
    while True:
        job: Job | None = get_job(job_id)
        if job is not None:
            payload = job_payload(job)
            if first or job.stage != last_stage:
                yield format_sse("job", payload)
                last_stage = job.stage
                last_idle = time.monotonic()
                first = False
            lifecycle = (
                derive_session_status(job),
                job.stage,
                stage_label(job.stage),
            )
            if lifecycle != last_lifecycle:
                yield format_sse(
                    "progress",
                    {
                        "session_status": lifecycle[0],
                        "stage": lifecycle[1],
                        "stage_label": lifecycle[2],
                        "job_status": job.status.value,
                    },
                )
                last_lifecycle = lifecycle
                last_idle = time.monotonic()
            if job.status.terminal:
                yield format_sse(_terminal_event(job.status), payload)
                return
        if time.monotonic() - last_idle > idle_seconds:
            yield format_sse("heartbeat", {"ts": time.time()})
            last_idle = time.monotonic()
        await asyncio.sleep(poll_seconds)
