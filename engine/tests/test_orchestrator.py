"""Orchestrator integration tests: full pipeline -> canonical session, resume,
idempotency, cancellation, retry (architecture §4.2, §2.1)."""

from __future__ import annotations

from collections import defaultdict
from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.errors import JobCanceledError, JobFailedError
from app.inputs.base import TranscriptionResult
from app.models import Job, JobKind, JobStatus
from app.providers.registry import (
    register_llm,
    register_transcriber,
    unregister_llm,
    unregister_transcriber,
)
from app.schemas import validate_session
from app.store import get_store
from app.workers.orchestrator import run_stages

CLEANED = "Hello world. We should ship v2 by Friday."
RAW = "uh hello world um we should ship v2 by Friday"

CANNED = {
    "cleanup": {
        "cleaned_text": CLEANED,
        "original_text": RAW,
    },
    "segmentation": {
        "segments": [
            {"position": 0, "title": "Intro", "text": "Hello world."},
            {
                "position": 1,
                "title": "Shipping",
                "text": "We should ship v2 by Friday.",
            },
        ]
    },
    "classification": {
        "topics": [
            {
                "position": 0,
                "title": "Greeting",
                "description": "Opening",
                "confidence": 0.9,
            },
            {
                "position": 1,
                "title": "Release plan",
                "description": "v2 deadline",
                "confidence": 0.8,
            },
        ]
    },
    "entity_extraction": {
        "entities": [
            {"name": "Friday", "type": "date", "aliases": [], "confidence": 0.9},
            {
                "name": "Benchmark Platform",
                "type": "project",
                "aliases": ["Benchmark"],
                "confidence": 0.95,
            },
        ],
        "relationships": [
            {
                "source": "Friday",
                "target": "Benchmark Platform",
                "type": "related_to",
                "confidence": 0.7,
            }
        ],
    },
    "task_extraction": {
        "tasks": [
            {
                "title": "Ship v2 by Friday",
                "type": "action",
                "priority": "high",
                "due": None,
                "confidence": 0.9,
            }
        ]
    },
    "knowledge_extraction": {
        "title": "Release plan",
        "alternative_titles": ["v2 shipping"],
        "summary": "We plan to ship v2 by Friday.",
        "summary_confidence": 0.8,
        "items": [
            {
                "type": "task",
                "title": "Ship v2",
                "description": None,
                "priority": "high",
                "confidence": 0.9,
                "topic_position": 1,
            }
        ],
    },
    "tags": {
        "tags": [
            {"name": "release planning", "confidence": 0.9},
            {"name": "shipping", "confidence": 0.8},
        ]
    },
}

OPTIONS = {
    "input_kind": "voice",
    "stt_provider": "test-stt",
    "stage": {"provider": "test-llm"},
    "input_meta": {"mime_type": "audio/webm"},
}


class FakeTranscriber:
    async def transcribe(self, blob_ref: str, *, language: str | None = None):
        return TranscriptionResult(text=RAW, language="en", confidence=0.95)


class FakeLLM:
    def __init__(self, canned: dict[str, object]) -> None:
        self.canned = canned
        self.fail_stage: str | None = None
        self.invalid_once_stage: str | None = None
        self.always_invalid_stages: set[str] = set()
        self.calls: dict[str, int] = defaultdict(int)

    async def complete(self, *args, **kwargs) -> str:
        return ""

    async def complete_structured(self, prompt, json_schema, **kwargs):
        stage = str(json_schema).split(".", 1)[1]
        self.calls[stage] += 1
        if stage == self.fail_stage:
            raise JobFailedError(f"{stage} exploded", code="STAGE_RUNTIME")
        if stage in self.always_invalid_stages:
            return {"unexpected": True}
        if stage == self.invalid_once_stage and self.calls[stage] == 1:
            return {"unexpected": True}
        return self.canned[stage]


@pytest.fixture
def providers():
    llm = FakeLLM(CANNED)
    register_llm("test-llm", llm)
    register_transcriber("test-stt", FakeTranscriber())
    yield llm
    unregister_llm("test-llm")
    unregister_transcriber("test-stt")


def _analyze_job(
    input_ref: str | None = "bucket/session-a/audio.webm", **options
) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=JobKind.analyze,
        status=JobStatus.queued,
        input_ref=input_ref,
        options={**OPTIONS, **options},
        created_at=now,
        updated_at=now,
    )


def _flatten_items(topics: list[dict]) -> list[dict]:
    return [item for topic in topics for item in topic["items"]]


async def test_full_pipeline_produces_validated_canonical_session(providers) -> None:
    store = get_store()
    job = store.create(_analyze_job())

    result = await run_stages(job)

    validate_session(result)  # canonical contract holds
    session = result["session"]
    assert result["schema_version"] == 1
    assert session["title"] == "Release plan"
    assert session["alternative_titles"] == ["v2 shipping"]
    assert session["summary_confidence"] == 0.8
    assert session["extraction_confidence"] == 0.9
    assert session["language"] == "en"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())
    assert session["tags"] == [
        {"name": "release planning", "confidence": 0.9},
        {"name": "shipping", "confidence": 0.8},
    ]
    assert session["prompt_versions"] == {
        stage: 2
        if stage in ("entity_extraction", "task_extraction", "knowledge_extraction")
        else 1
        for stage in (
            "cleanup",
            "segmentation",
            "classification",
            "entity_extraction",
            "task_extraction",
            "knowledge_extraction",
            "tags",
            "validation",
            "embedding",
        )
    }

    # Knowledge graph: deterministic entity ids + edges without dangling ends.
    assert session["entities"][0]["name"] == "Friday"
    assert session["entities"][0]["type"] == "date"
    assert session["entities"][0]["id"]
    assert session["entities"][1]["name"] == "Benchmark Platform"
    assert session["entities"][1]["aliases"] == ["Benchmark"]
    assert len(session["relationships"]) == 1
    edge = session["relationships"][0]
    assert edge["type"] == "related_to"
    assert {edge["source_id"], edge["target_id"]} == {
        e["id"] for e in session["entities"]
    }
    assert edge["confidence"] == 0.7

    titles = [t["title"] for t in session["topics"]]
    assert titles == ["Greeting", "Release plan"]
    items = _flatten_items(session["topics"])
    assert len(items) == 1
    assert items[0]["type"] == "task"
    assert items[0]["priority"] == "high"

    updated = store.get(job.id)
    assert updated is not None
    assert updated.stage == "embedding"  # process_job clears stage on success
    assert set(updated.intermediates or {}) == set(CANNED) | {"validation", "embedding"}
    for name, output in CANNED.items():
        assert updated.intermediates[name] == output


async def test_transcript_input_runs_pipeline_without_stt(providers) -> None:
    """An edited-transcript re-run skips STT and feeds the text straight in."""
    store = get_store()
    job = store.create(
        _analyze_job(
            input_ref=None,
            input_kind="transcript",
            stt_provider=None,
            input_meta={"text": "We should ship v2 by Friday."},
        )
    )

    result = await run_stages(job)

    validate_session(result)  # canonical contract holds for the transcript path
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())
    # The transcript text fed the cleanup stage as the input transcript.
    updated = store.get(job.id)
    assert updated is not None
    assert updated.intermediates["cleanup"]["original_text"] == RAW


async def test_note_input_runs_pipeline_without_stt(providers) -> None:
    """A manual note is re-ingestible from `input_meta.text` alone (§4.12)."""
    store = get_store()
    job = store.create(
        _analyze_job(
            input_ref=None,
            input_kind="note",
            stt_provider=None,
            input_meta={
                "text": "We should ship v2 by Friday.",
                "title": "Offsite prep",
            },
        )
    )

    result = await run_stages(job)

    validate_session(result)  # canonical contract holds for the note path
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())
    updated = store.get(job.id)
    assert updated is not None
    assert updated.intermediates["cleanup"]["original_text"] == RAW
    assert updated.error is None


async def test_image_input_runs_pipeline_with_ocr(providers) -> None:
    """An image job OCR-extracts text and runs the full pipeline from there."""
    from app.providers.registry import (
        register_ocr,
        unregister_ocr,
    )

    class _FakeOcr:
        async def extract_text(self, blob_ref, *, mime_type=None):
            from app.inputs.base import OcrResult

            return OcrResult(text=RAW, confidence=0.87)

    register_ocr("test-ocr", _FakeOcr())
    try:
        store = get_store()
        job = store.create(
            _analyze_job(
                input_ref="bucket/session-a/photo.png",
                input_kind="image",
                stt_provider=None,
                ocr_provider="test-ocr",
                input_meta={"mime_type": "image/png"},
            )
        )

        result = await run_stages(job)
    finally:
        unregister_ocr("test-ocr")

    validate_session(result)  # canonical contract holds for the image path
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())
    updated = store.get(job.id)
    assert updated is not None
    assert updated.intermediates["cleanup"]["original_text"] == RAW
    assert updated.error is None


async def test_pdf_input_runs_pipeline_with_ocr(providers) -> None:
    """A PDF job OCR-extracts text and runs the full pipeline from there."""
    from app.inputs.base import OcrResult
    from app.providers.registry import (
        register_ocr,
        unregister_ocr,
    )

    class _FakeOcr:
        async def extract_text(self, blob_ref, *, mime_type=None):
            return OcrResult(text=RAW, confidence=0.8)

    register_ocr("test-ocr-pdf", _FakeOcr())
    try:
        store = get_store()
        job = store.create(
            _analyze_job(
                input_ref="bucket/session-a/doc.pdf",
                input_kind="pdf",
                stt_provider=None,
                ocr_provider="test-ocr-pdf",
                input_meta={"mime_type": "application/pdf"},
            )
        )

        await run_stages(job)
        updated = store.get(job.id)
        assert updated is not None
        assert updated.intermediates["cleanup"]["original_text"] == RAW
        assert updated.error is None
    finally:
        unregister_ocr("test-ocr-pdf")


async def test_screenshot_input_runs_pipeline_with_ocr(providers) -> None:
    """A screenshot job OCR-extracts text via the image path and runs the full
    pipeline unchanged from there."""
    from app.inputs.base import OcrResult
    from app.providers.registry import (
        register_ocr,
        unregister_ocr,
    )

    class _FakeOcr:
        async def extract_text(self, blob_ref, *, mime_type=None):
            return OcrResult(text=RAW, confidence=0.82)

    register_ocr("test-ocr-shot", _FakeOcr())
    try:
        store = get_store()
        job = store.create(
            _analyze_job(
                input_ref="bucket/session-a/shot.png",
                input_kind="screenshot",
                stt_provider=None,
                ocr_provider="test-ocr-shot",
                input_meta={"mime_type": "image/png"},
            )
        )

        result = await run_stages(job)
    finally:
        unregister_ocr("test-ocr-shot")

    validate_session(result)  # canonical contract holds for the screenshot path
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())
    updated = store.get(job.id)
    assert updated is not None
    assert updated.intermediates["cleanup"]["original_text"] == RAW
    assert updated.error is None


async def test_email_input_runs_pipeline_with_parser(providers) -> None:
    """An email job parses the message and runs the full pipeline from there."""
    from app.inputs.base import ParsedDocument
    from app.providers.registry import (
        register_parser,
        unregister_parser,
    )

    class _FakeParser:
        async def parse(self, blob_ref, *, mime_type=None, user_id=None):
            return ParsedDocument(text=RAW, title="Re: release", confidence=0.99)

    register_parser("test-parser", _FakeParser())
    try:
        store = get_store()
        job = store.create(
            _analyze_job(
                input_ref="bucket/session-a/inbox.eml",
                input_kind="email",
                stt_provider=None,
                parser_provider="test-parser",
                input_meta={"mime_type": "message/rfc822"},
            )
        )

        result = await run_stages(job)
        updated = store.get(job.id)
        assert updated is not None
        assert updated.intermediates["cleanup"]["original_text"] == RAW
        assert updated.error is None
    finally:
        unregister_parser("test-parser")

    validate_session(result)
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())


async def test_document_input_runs_pipeline_with_parser(providers) -> None:
    """A document job parses the blob and runs the full pipeline from there."""
    from app.inputs.base import ParsedDocument
    from app.providers.registry import (
        register_parser,
        unregister_parser,
    )

    class _FakeParser:
        async def parse(self, blob_ref, *, mime_type=None, user_id=None):
            return ParsedDocument(text=RAW, confidence=1.0)

    register_parser("test-parser-doc", _FakeParser())
    try:
        store = get_store()
        job = store.create(
            _analyze_job(
                input_ref="bucket/session-a/budget.docx",
                input_kind="document",
                stt_provider=None,
                parser_provider="test-parser-doc",
                input_meta={
                    "mime_type": (
                        "application/vnd.openxmlformats-officedocument"
                        ".wordprocessingml.document"
                    )
                },
            )
        )

        result = await run_stages(job)
        updated = store.get(job.id)
        assert updated is not None
        assert updated.intermediates["cleanup"]["original_text"] == RAW
        assert updated.error is None
    finally:
        unregister_parser("test-parser-doc")

    validate_session(result)
    session = result["session"]
    assert session["title"] == "Release plan"
    assert session["status"] == "ready"
    assert session["word_count"] == len(CLEANED.split())


async def test_voice_requires_input_ref(providers) -> None:
    """Blob-backed inputs still reject a missing ref; transcript does not."""
    store = get_store()
    job = store.create(_analyze_job(input_ref=None))

    with pytest.raises(JobFailedError) as exc:
        await run_stages(job)
    assert exc.value.code == "INPUT_INVALID"


async def test_process_job_success_path(providers) -> None:
    from app.workers.orchestrator import process_job

    store = get_store()
    job = store.create(_analyze_job())

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.succeeded
    validate_session(updated.result)
    assert updated.error is None


async def test_stage_failure_is_structured_and_resumable(providers) -> None:
    providers.fail_stage = "segmentation"
    store = get_store()
    job = store.create(_analyze_job())

    with pytest.raises(JobFailedError) as exc:
        await run_stages(job)
    assert exc.value.code == "STAGE_RUNTIME"

    updated = store.get(job.id)
    assert updated is not None
    assert updated.stage == "cleanup"  # last completed stage is the resume point
    assert set(updated.intermediates or {}) == {"cleanup"}


async def test_resume_reruns_only_failed_stage(providers) -> None:
    from app.workers.orchestrator import process_job

    providers.fail_stage = "segmentation"
    store = get_store()
    job = store.create(_analyze_job())
    process_job(job.id)
    assert store.get(job.id).status == JobStatus.failed

    providers.fail_stage = None
    resumed = store.get(job.id).with_updated(status=JobStatus.queued, error=None)
    store.update(resumed)
    process_job(resumed.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.succeeded
    validate_session(updated.result)
    # Completed stages are not re-run (idempotent); the failed one is.
    assert providers.calls["cleanup"] == 1
    assert providers.calls["segmentation"] == 2


async def test_resume_without_failure_is_idempotent(providers) -> None:
    from app.workers.orchestrator import process_job

    store = get_store()
    job = store.create(_analyze_job())
    process_job(job.id)
    assert store.get(job.id).status == JobStatus.succeeded

    process_job(job.id)  # re-dispatch is a no-op

    assert providers.calls["cleanup"] == 1
    assert store.get(job.id).status == JobStatus.succeeded


async def test_cancelled_job_aborts_pipeline(providers) -> None:
    store = get_store()
    job = store.create(_analyze_job().with_updated(status=JobStatus.cancelled))

    with pytest.raises(JobCanceledError):
        await run_stages(job)


async def test_token_budget_stops_oversized_stage_input(providers, monkeypatch) -> None:
    from app.config import settings

    monkeypatch.setattr(settings, "max_input_tokens", 1)
    store = get_store()
    job = store.create(_analyze_job())

    with pytest.raises(JobFailedError) as exc:
        await run_stages(job)
    assert exc.value.code == "TOKEN_BUDGET_EXCEEDED"
    assert exc.value.details["stage"] == "cleanup"


async def test_malformed_output_retries_then_succeeds(providers) -> None:
    providers.invalid_once_stage = "cleanup"
    store = get_store()
    job = store.create(_analyze_job())

    result = await run_stages(job)

    validate_session(result)
    assert providers.calls["cleanup"] == 2


async def test_persistently_malformed_output_fails_after_retry(providers) -> None:
    providers.always_invalid_stages = {"cleanup"}
    store = get_store()
    job = store.create(_analyze_job())

    with pytest.raises(JobFailedError) as exc:
        await run_stages(job)
    assert exc.value.code == "STAGE_OUTPUT_INVALID"
    assert exc.value.details["stage"] == "cleanup"
    assert exc.value.details["attempts"] == 2


async def test_resolved_prompt_versions_recorded(providers) -> None:
    store = get_store()
    job = store.create(_analyze_job())

    result = await run_stages(job)

    assert result["session"]["prompt_versions"]["cleanup"] == 1


async def test_async_entrypoint_is_runnable() -> None:
    from app.workers.orchestrator import process_job

    store = get_store()
    job = store.create(_analyze_job())
    # No providers registered here; failure must be a structured, resumable
    # NO_PROVIDER error rather than a crash.
    process_job(job.id)
    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "NO_PROVIDER"
