"""Pydantic models for the engine API (architecture §7.1)."""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.schemas import job_schema, validate_against_schema


class JobKind(str, Enum):
    transcribe = "transcribe"
    analyze = "analyze"
    rewrite = "rewrite"
    chat = "chat"
    command = "command"
    insights = "insights"


class JobStatus(str, Enum):
    queued = "queued"
    running = "running"
    succeeded = "succeeded"
    failed = "failed"
    cancelled = "cancelled"

    @property
    def terminal(self) -> bool:
        return self in (JobStatus.succeeded, JobStatus.failed, JobStatus.cancelled)


class ErrorDetail(BaseModel):
    code: str
    message: str
    details: dict[str, Any] | None = None


class JobCreateRequest(BaseModel):
    kind: JobKind
    input_ref: str | None = None
    options: dict[str, Any] | None = None
    prompt_versions: dict[str, int] | None = None


class ProviderSecretRequest(BaseModel):
    """Server-side provider credential upsert (architecture §12)."""

    api_key: str = Field(min_length=1, max_length=4096)


class Job(BaseModel):
    """Job record exchanged over the API; mirrors the drift `jobs` table."""

    model_config = ConfigDict(extra="allow")

    id: str
    user_id: str
    kind: JobKind
    status: JobStatus
    stage: str | None = None
    input_ref: str | None = None
    options: dict[str, Any] | None = None
    prompt_versions: dict[str, int] | None = None
    intermediates: dict[str, Any] | None = None
    result: dict[str, Any] | None = None
    error: ErrorDetail | None = None
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))

    def validate_schema(self) -> None:
        validate_against_schema(self.model_dump(mode="json"), job_schema())

    def with_updated(self, **changes: Any) -> "Job":
        data = self.model_dump(mode="json", exclude_none=True)
        data.update(changes)
        data.setdefault("updated_at", datetime.now(timezone.utc))
        return Job.model_validate(data)


class Envelope(BaseModel):
    model_config = ConfigDict(exclude_none=True)

    status: str = "ok"
    data: dict[str, Any] | None = None
    error: ErrorDetail | None = None
