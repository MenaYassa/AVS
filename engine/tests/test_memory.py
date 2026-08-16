"""AI memory context tests (architecture §4.9, spec §19).

Covers the opt-in memory block: normalization/validation bounds, the
source-tagged prompt rendering, injection into chat and the analysis pipeline
stages that consume memory, and the structural failure path. No provider I/O —
provider output is faked and the prompt bytes are the unit under test.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.errors import JobFailedError
from app.memory import normalize_memory, render_memory_block
from app.models import Job, JobKind, JobStatus
from app.providers.registry import register_llm, unregister_llm
from app.providers.stt import TranscriptionResult
from app.workers.orchestrator import run_stages

from test_orchestrator import (  # type: ignore[import-not-found]
    CANNED,
    RAW,
    _analyze_job,
)


def _descriptors() -> list[dict[str, object]]:
    return [
        {
            "session_id": "session-b",
            "title": "Benchmark kickoff",
            "summary": "We set up the benchmark harness for the release.",
            "open_tasks": ["Write the harness", "Run first sweep"],
        }
    ]


def test_normalize_memory_absent_is_opt_out() -> None:
    assert normalize_memory(None) == []
    assert normalize_memory([]) == []


def test_normalize_memory_rejects_non_list() -> None:
    with pytest.raises(JobFailedError) as exc:
        normalize_memory("not-a-list")
    assert exc.value.code == "MEMORY_CONTEXT_INVALID"


def test_normalize_memory_requires_session_id_and_content() -> None:
    with pytest.raises(JobFailedError) as exc:
        normalize_memory([{"title": "No id"}])
    assert exc.value.code == "MEMORY_CONTEXT_INVALID"
    with pytest.raises(JobFailedError) as exc:
        normalize_memory([{"session_id": "s"}])
    assert exc.value.code == "MEMORY_CONTEXT_INVALID"


def test_normalize_memory_bounds_entries_tasks_and_text() -> None:
    raw = [
        {
            "session_id": f"s{i}",
            "title": "T" * 500,
            "summary": "S" * 500,
            "open_tasks": [f"task {j}" for j in range(20)],
        }
        for i in range(20)
    ]
    items = normalize_memory(raw)
    assert len(items) == 8  # _MAX_MEMORY_ENTRIES
    assert all(len(i["title"]) <= 200 for i in items)
    assert all(len(i["summary"]) <= 400 for i in items)
    assert all(len(i["open_tasks"]) <= 6 for i in items)
    # non-string tasks are skipped, strings are truncated
    normalized = normalize_memory([{"session_id": "s", "open_tasks": [42, "a" * 500]}])
    assert normalized[0]["open_tasks"] == ["a" * 200]


def test_render_memory_block_empty() -> None:
    assert render_memory_block([]) == ""


def test_render_memory_block_is_source_tagged() -> None:
    block = render_memory_block(_descriptors())
    assert "[source: session-b]" in block
    assert "Benchmark kickoff" in block
    assert "We set up the benchmark harness for the release." in block
    assert "Write the harness; Run first sweep" in block


def test_render_memory_block_bounds_total_chars() -> None:
    many = [
        {"session_id": f"s{i}", "title": "X" * 1000, "summary": "Y" * 1000}
        for i in range(8)
    ]
    block = render_memory_block(many)
    assert len(block) <= 6000
    assert "[source: s0]" in block
    assert len(block) < 8 * 2000  # aggregate budget truncated the tail


class _CapturingMemoryLLM:
    """Returns canned per-stage output and records the rendered prompts."""

    def __init__(self, canned: dict[str, object]) -> None:
        self.canned = canned
        self.prompts: dict[str, str] = {}

    async def complete(self, *args, **kwargs) -> str:
        return ""

    async def complete_structured(self, prompt, json_schema, **kwargs):
        stage = str(json_schema).split(".", 1)[1]
        self.prompts[stage] = prompt
        return self.canned[stage]


class _FakeTranscriber:
    async def transcribe(self, blob_ref: str, *, language: str | None = None):
        return TranscriptionResult(text=RAW, language="en", confidence=0.95)


@pytest.fixture
def pipeline_llm():
    from app.providers.registry import register_transcriber, unregister_transcriber

    llm = _CapturingMemoryLLM(CANNED)
    register_llm("test-llm", llm)
    register_transcriber("test-stt", _FakeTranscriber())
    yield llm
    unregister_llm("test-llm")
    unregister_transcriber("test-stt")


async def test_pipeline_injects_memory_into_memory_aware_stages(
    pipeline_llm,
) -> None:
    from app.store import get_store

    job = get_store().create(_analyze_job(memory=_descriptors()))
    result = await run_stages(job)

    assert result["schema_version"] == 1  # canonical contract still holds
    task_prompt = pipeline_llm.prompts["task_extraction"]
    knowledge_prompt = pipeline_llm.prompts["knowledge_extraction"]
    for prompt in (task_prompt, knowledge_prompt):
        assert "[source: session-b]" in prompt
        assert "Benchmark kickoff" in prompt
    assert "[source: session-b]" not in pipeline_llm.prompts["segmentation"]


async def test_pipeline_without_memory_renders_empty_block(pipeline_llm) -> None:
    from app.store import get_store

    await run_stages(get_store().create(_analyze_job()))
    for stage in ("task_extraction", "knowledge_extraction"):
        prompt = pipeline_llm.prompts[stage]
        assert "[source:" not in prompt


async def test_pipeline_rejects_malformed_memory() -> None:
    from app.errors import JobFailedError
    from app.store import get_store

    job = get_store().create(_analyze_job(memory=[{"summary": "no session id"}]))
    with pytest.raises(JobFailedError) as exc:
        await run_stages(job)
    assert exc.value.code == "MEMORY_CONTEXT_INVALID"


def _chat_job(**options) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=JobKind.chat,
        status=JobStatus.queued,
        input_ref=None,
        options=options,
        created_at=now,
        updated_at=now,
    )


class _ChatLLM:
    def __init__(self) -> None:
        self.last_prompt: str | None = None

    async def complete(self, *args, **kwargs) -> str:
        return ""

    async def complete_structured(self, prompt, json_schema, **kwargs):
        self.last_prompt = prompt
        return {
            "answer": "The harness is being set up.",
            "citations": ["[memory: Benchmark kickoff]"],
            "confidence": 0.7,
        }


@pytest.fixture
def chat_llm():
    llm = _ChatLLM()
    register_llm("test-llm", llm)
    yield llm
    unregister_llm("test-llm")


async def test_chat_renders_memory_into_prompt(chat_llm) -> None:
    from app.commands.chat_runner import run_chat

    result = await run_chat(
        _chat_job(
            question="What is the status of the harness?",
            stage={"provider": "test-llm"},
            context={
                "session_id": "session-a",
                "title": "Release planning",
                "transcript": "We need to finish the harness.",
            },
            memory=_descriptors(),
        )
    )
    assert result["prompt_versions"] == {"chat": 2}
    assert "[source: session-b]" in chat_llm.last_prompt
    assert "Benchmark kickoff" in chat_llm.last_prompt


async def test_chat_without_memory_has_no_memory_block(chat_llm) -> None:
    from app.commands.chat_runner import run_chat

    await run_chat(
        _chat_job(
            question="What is the status?",
            stage={"provider": "test-llm"},
            context={"session_id": "session-a", "title": "Release planning"},
        )
    )
    assert "[source:" not in chat_llm.last_prompt


async def test_chat_rejects_malformed_memory(chat_llm) -> None:
    from app.commands.chat_runner import run_chat

    job = _chat_job(
        question="What is the status?",
        stage={"provider": "test-llm"},
        context={"session_id": "session-a"},
        memory="nope",
    )
    with pytest.raises(JobFailedError) as exc:
        await run_chat(job)
    assert exc.value.code == "MEMORY_CONTEXT_INVALID"


def test_chat_prompt_contract_mandates_source_citations() -> None:
    """§5.6 provenance: the chat prompt that *generates* answers must demand
    inline citations of every claim, including `[memory: "Title"]` sources, so
    a memory-backed answer is never allowed to present unsourced content."""
    from app.commands.chat_runner import CHAT_PROMPT_NAME
    from app.prompts.registry import get_prompt_registry

    asset = get_prompt_registry().latest(CHAT_PROMPT_NAME)
    template = asset.user_prompt_template
    assert "citing sources inline like" in template
    assert '[memory: "Title"]' in template
    assert "[transcript]" in template
    assert "citations" in template
    assert "never hallucinate" in asset.system_prompt
