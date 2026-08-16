"""Session lifecycle state machine (architecture §4.5).

Every session is a state machine:

    recording -> uploading -> transcribing -> cleaning -> analyzing
        -> validating -> ready -> (user edits) -> edited -> synced

with terminal `failed` / `cancelled`. The engine owns the pipeline half of the
machine; the app owns `recording`/`uploading` and the post-`ready` edits.
`derive_session_status` projects a job record onto this machine (job status +
last completed stage -> session status), and `job_payload` enriches job records
exchanged over the API/SSE with the derived status and a human-readable stage
label so clients render the same lifecycle without duplicating the mapping.
"""

from __future__ import annotations

from enum import Enum
from typing import Any

from app.models import Job, JobKind, JobStatus
from app.stages.names import (
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_ENTITY_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_SEGMENTATION,
    STAGE_TAGS,
    STAGE_TASK_EXTRACTION,
    STAGE_VALIDATION,
)


class SessionLifecycle(str, Enum):
    """Values mirror `session_status` in the canonical schema (§5.1)."""

    recording = "recording"
    uploading = "uploading"
    transcribing = "transcribing"
    cleaning = "cleaning"
    analyzing = "analyzing"
    validating = "validating"
    ready = "ready"
    edited = "edited"
    synced = "synced"
    failed = "failed"
    cancelled = "cancelled"


#: Last-completed stage -> session lifecycle status (architecture §4.2 records
#: the last completed stage on the job; the derived status trails the live stage
#: by exactly one step, which is fine for user-visible progress).
_PIPELINE_STATUS: dict[str | None, str] = {
    None: SessionLifecycle.transcribing.value,
    STAGE_CLEANUP: SessionLifecycle.cleaning.value,
    STAGE_SEGMENTATION: SessionLifecycle.analyzing.value,
    STAGE_CLASSIFICATION: SessionLifecycle.analyzing.value,
    STAGE_ENTITY_EXTRACTION: SessionLifecycle.analyzing.value,
    STAGE_TASK_EXTRACTION: SessionLifecycle.analyzing.value,
    STAGE_KNOWLEDGE_EXTRACTION: SessionLifecycle.analyzing.value,
    STAGE_TAGS: SessionLifecycle.analyzing.value,
    STAGE_VALIDATION: SessionLifecycle.validating.value,
}

#: Human-readable label for a pipeline stage (UI stage labels, §2.4).
_STAGE_LABELS: dict[str | None, str] = {
    None: "Transcribing",
    STAGE_CLEANUP: "Cleaning up",
    STAGE_SEGMENTATION: "Segmenting",
    STAGE_CLASSIFICATION: "Classifying",
    STAGE_ENTITY_EXTRACTION: "Extracting entities",
    STAGE_TASK_EXTRACTION: "Extracting tasks",
    STAGE_KNOWLEDGE_EXTRACTION: "Generating knowledge",
    STAGE_TAGS: "Tagging",
    STAGE_VALIDATION: "Validating",
}


def stage_label(stage: str | None) -> str:
    return _STAGE_LABELS.get(stage, "Processing")


def derive_session_status(job: Job) -> str | None:
    """Project a job onto the session lifecycle; None for non-session kinds."""
    if job.kind != JobKind.analyze:
        return None
    if job.status is JobStatus.cancelled:
        return SessionLifecycle.cancelled.value
    if job.status is JobStatus.failed:
        return SessionLifecycle.failed.value
    if job.status is JobStatus.succeeded:
        return SessionLifecycle.ready.value
    if job.status is JobStatus.running:
        return _PIPELINE_STATUS.get(job.stage, SessionLifecycle.analyzing.value)
    # queued: fresh job (no stage yet) is uploading; a resumed job shows the
    # stage it will continue from.
    if job.stage is None:
        return SessionLifecycle.uploading.value
    return _PIPELINE_STATUS.get(job.stage, SessionLifecycle.uploading.value)


def job_payload(job: Job) -> dict[str, Any]:
    """Envelope data for a job record, enriched with lifecycle projections."""
    payload = job.model_dump(mode="json", exclude_none=True)
    status = derive_session_status(job)
    if status is not None:
        payload["session_status"] = status
        payload["stage_label"] = stage_label(job.stage)
    return payload


#: Legal transitions. Idempotent re-assertions are allowed for non-terminal
#: states; terminal states (`failed` resumes via upload, `cancelled` is final).
_TRANSITIONS: dict[str, set[str]] = {
    SessionLifecycle.recording.value: {
        SessionLifecycle.uploading.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.uploading.value: {
        SessionLifecycle.transcribing.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.transcribing.value: {
        SessionLifecycle.cleaning.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.cleaning.value: {
        SessionLifecycle.analyzing.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.analyzing.value: {
        SessionLifecycle.validating.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.validating.value: {
        SessionLifecycle.ready.value,
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    },
    SessionLifecycle.ready.value: {
        SessionLifecycle.edited.value,
        SessionLifecycle.synced.value,
    },
    SessionLifecycle.edited.value: {
        SessionLifecycle.edited.value,
        SessionLifecycle.synced.value,
    },
    SessionLifecycle.synced.value: {
        SessionLifecycle.edited.value,
        SessionLifecycle.synced.value,
    },
    SessionLifecycle.failed.value: {
        SessionLifecycle.uploading.value,  # resume from last completed stage
    },
    SessionLifecycle.cancelled.value: set(),
}


def can_transition(current: str, next_state: str) -> bool:
    if current not in _TRANSITIONS:
        return False
    if next_state == current and current not in (
        SessionLifecycle.failed.value,
        SessionLifecycle.cancelled.value,
    ):
        return True  # idempotent re-assertion
    return next_state in _TRANSITIONS[current]


def validate_transition(current: str, next_state: str) -> None:
    """Raise ValueError on an illegal lifecycle jump."""
    if not can_transition(current, next_state):
        raise ValueError(
            f"illegal session lifecycle transition: {current!r} -> {next_state!r}"
        )
