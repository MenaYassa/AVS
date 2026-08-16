"""Cross-session insights endpoint (architecture §7.1, §4.9).

`POST /api/v1/insights` is the dedicated entrypoint for cross-session
intelligence. It is a thin job factory: it packages the shipped session
descriptors into an `insights` job (`options.sessions`) and hands it to the
same queue + SSE machinery every other kind uses, so the client gets the same
202 / status / stream lifecycle it already has for chat and commands.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field

from app.auth import authenticate
from app.lifecycle import job_payload
from app.models import Envelope, Job, JobKind, JobStatus
from app.queue import enqueue
from app.store import get_store

router = APIRouter(prefix="/api/v1", tags=["insights"])


async def _current_user(request: Request) -> str:
    return await authenticate(request)


class InsightSession(BaseModel):
    """One compact session descriptor shipped by the client (privacy, §4.9).

    The engine computes from exactly what the client shares — no server-side
    data access, so nothing beyond the user's own app is ever in scope.
    """

    model_config = ConfigDict(extra="allow")

    session_id: str = Field(min_length=1)
    title: str = ""
    summary: str = ""
    transcript: str = ""
    tags: list[str] = Field(default_factory=list)
    entities: list[str] = Field(default_factory=list)
    items: list[dict[str, Any]] = Field(default_factory=list)


class InsightsRequest(BaseModel):
    sessions: list[InsightSession] = Field(min_length=1)
    options: dict[str, Any] | None = None


@router.post("/insights", status_code=202, response_model_exclude_none=True)
async def create_insights(
    body: InsightsRequest,
    user_id: str = Depends(_current_user),
) -> Envelope:
    now = datetime.now(timezone.utc)
    options = {
        **(body.options or {}),
        "sessions": [s.model_dump() for s in body.sessions],
    }
    job = Job(
        id=str(uuid4()),
        user_id=user_id,
        kind=JobKind.insights,
        status=JobStatus.queued,
        stage=None,
        input_ref=None,
        options=options,
        created_at=now,
        updated_at=now,
    )
    job.validate_schema()
    get_store().create(job)
    enqueue(job)
    return Envelope(data=job_payload(job))
