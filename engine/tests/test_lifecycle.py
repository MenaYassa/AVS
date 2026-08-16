"""Session lifecycle tests (architecture §4.5)."""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.lifecycle import (
    SessionLifecycle,
    can_transition,
    derive_session_status,
    job_payload,
    stage_label,
    validate_transition,
)
from app.models import Job, JobKind, JobStatus
from app.stages.names import (
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_ENTITY_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_SEGMENTATION,
    STAGE_TASK_EXTRACTION,
    STAGE_VALIDATION,
)


def _job(
    *,
    status: JobStatus,
    kind: JobKind = JobKind.analyze,
    stage: str | None = None,
) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=kind,
        status=status,
        stage=stage,
        created_at=now,
        updated_at=now,
    )


class TestDeriveSessionStatus:
    @pytest.mark.parametrize(
        ("job", "expected"),
        [
            (_job(status=JobStatus.queued), "uploading"),
            (_job(status=JobStatus.queued, stage=STAGE_CLASSIFICATION), "analyzing"),
            (_job(status=JobStatus.running), "transcribing"),
            (_job(status=JobStatus.running, stage=STAGE_CLEANUP), "cleaning"),
            (_job(status=JobStatus.running, stage=STAGE_SEGMENTATION), "analyzing"),
            (_job(status=JobStatus.running, stage=STAGE_CLASSIFICATION), "analyzing"),
            (
                _job(status=JobStatus.running, stage=STAGE_ENTITY_EXTRACTION),
                "analyzing",
            ),
            (
                _job(status=JobStatus.running, stage=STAGE_TASK_EXTRACTION),
                "analyzing",
            ),
            (
                _job(status=JobStatus.running, stage=STAGE_KNOWLEDGE_EXTRACTION),
                "analyzing",
            ),
            (_job(status=JobStatus.running, stage=STAGE_VALIDATION), "validating"),
            (_job(status=JobStatus.succeeded), "ready"),
            (_job(status=JobStatus.failed), "failed"),
            (_job(status=JobStatus.cancelled), "cancelled"),
        ],
    )
    def test_matrix(self, job: Job, expected: str) -> None:
        assert derive_session_status(job) == expected

    def test_non_analyze_kinds_have_no_session(self) -> None:
        for kind in (JobKind.transcribe, JobKind.rewrite, JobKind.chat):
            assert (
                derive_session_status(_job(status=JobStatus.running, kind=kind)) is None
            )

    def test_unknown_stage_is_analyzing(self) -> None:
        job = _job(status=JobStatus.running, stage="mystery_stage")
        assert derive_session_status(job) == "analyzing"


class TestStageLabel:
    def test_every_stage_has_a_label(self) -> None:
        assert stage_label(STAGE_CLEANUP) == "Cleaning up"
        assert stage_label(STAGE_SEGMENTATION) == "Segmenting"
        assert stage_label(STAGE_CLASSIFICATION) == "Classifying"
        assert stage_label(STAGE_ENTITY_EXTRACTION) == "Extracting entities"
        assert stage_label(STAGE_TASK_EXTRACTION) == "Extracting tasks"
        assert stage_label(STAGE_KNOWLEDGE_EXTRACTION) == "Generating knowledge"
        assert stage_label(STAGE_VALIDATION) == "Validating"

    def test_pre_pipeline_and_unknown(self) -> None:
        assert stage_label(None) == "Transcribing"
        assert stage_label("nope") == "Processing"


class TestJobPayload:
    def test_analyze_job_is_enriched(self) -> None:
        job = _job(status=JobStatus.running, stage=STAGE_CLEANUP)
        payload = job_payload(job)
        assert payload["session_status"] == "cleaning"
        assert payload["stage_label"] == "Cleaning up"

    def test_non_analyze_job_is_not_enriched(self) -> None:
        job = _job(status=JobStatus.running, kind=JobKind.chat)
        assert "session_status" not in job_payload(job)
        assert "stage_label" not in job_payload(job)

    def test_succeeded_job_is_ready(self) -> None:
        job = _job(status=JobStatus.succeeded)
        assert job_payload(job)["session_status"] == "ready"


class TestTransitions:
    def test_happy_path(self) -> None:
        path = [
            "recording",
            "uploading",
            "transcribing",
            "cleaning",
            "analyzing",
            "validating",
            "ready",
            "edited",
            "synced",
        ]
        for current, next_state in zip(path, path[1:]):
            assert can_transition(current, next_state)
            validate_transition(current, next_state)

    def test_idempotent_reassertion_allowed(self) -> None:
        for state in ("uploading", "analyzing", "ready", "edited", "synced"):
            assert can_transition(state, state)

    def test_terminal_states_are_stable(self) -> None:
        assert not can_transition("cancelled", "uploading")
        assert not can_transition("cancelled", "cancelled")
        assert not can_transition("failed", "ready")

    def test_failure_anywhere(self) -> None:
        for state in (
            "recording",
            "uploading",
            "transcribing",
            "cleaning",
            "analyzing",
            "validating",
        ):
            assert can_transition(state, "failed")
            assert can_transition(state, "cancelled")

    def test_resume_from_failure(self) -> None:
        assert can_transition("failed", "uploading")

    def test_ready_edits_and_resync(self) -> None:
        assert can_transition("ready", "edited")
        assert can_transition("edited", "synced")
        assert can_transition("synced", "edited")  # new edits after sync

    def test_illegal_jump_raises(self) -> None:
        with pytest.raises(ValueError, match="illegal"):
            validate_transition("recording", "ready")
        with pytest.raises(ValueError, match="illegal"):
            validate_transition("uploading", "validating")

    def test_unknown_state_rejected(self) -> None:
        assert not can_transition("uploading", "vaporware")
        assert not can_transition("vaporware", "ready")

    def test_enum_values_match_schema(self) -> None:
        assert SessionLifecycle.ready.value == "ready"
        assert set(SessionLifecycle) == {
            SessionLifecycle(s)
            for s in (
                "recording",
                "uploading",
                "transcribing",
                "cleaning",
                "analyzing",
                "validating",
                "ready",
                "edited",
                "synced",
                "failed",
                "cancelled",
            )
        }
