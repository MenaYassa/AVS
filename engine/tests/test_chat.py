"""AI chat tests (architecture §4.11, spec §23).

Exercises the chat runner, the worker dispatch path, and the API surface for
`kind: chat` jobs. Provider output is faked; the runner's grounding + schema
validation is the unit under test alongside the job plumbing.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.commands.chat_runner import run_chat
from app.errors import JobFailedError
from app.models import Job, JobKind, JobStatus
from app.providers.registry import register_llm, unregister_llm
from app.store import get_store
from app.workers.orchestrator import process_job

CONTEXT: dict[str, object] = {
    "session_id": "session-a",
    "title": "Release planning",
    "summary": "We plan to ship v2 by Friday.",
    "transcript": "Hello world. We should ship v2 by Friday.",
    "tags": [{"name": "release planning"}],
    "topics": [
        {
            "title": "Release plan",
            "description": "v2 deadline",
            "items": [{"title": "Ship v2", "description": "Friday", "type": "task"}],
        }
    ],
}


class FakeChatLLM:
    """Returns a schema-valid chat response on every call, capturing the prompt."""

    def __init__(self, response: dict[str, object]) -> None:
        self.response = response
        self.last_prompt: str | None = None
        self.last_schema: str | None = None

    async def complete(self, *args, **kwargs) -> str:
        return ""

    async def complete_structured(self, prompt, json_schema, **kwargs):
        self.last_prompt = prompt
        self.last_schema = str(json_schema)
        return self.response


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


@pytest.fixture
def llm():
    fake = FakeChatLLM(
        {
            "answer": "We should ship v2 by Friday.",
            "citations": ["[summary] Release planning"],
            "confidence": 0.95,
        }
    )
    register_llm("test-llm", fake)
    yield fake
    unregister_llm("test-llm")


async def test_chat_produces_a_grounded_answer(llm) -> None:
    result = await run_chat(
        _chat_job(
            question="When should we ship v2?",
            stage={"provider": "test-llm"},
            context=CONTEXT,
        )
    )
    assert result["question"] == "When should we ship v2?"
    assert result["session_id"] == "session-a"
    assert result["prompt_versions"] == {"chat": 2}
    response = result["response"]
    assert response["answer"] == "We should ship v2 by Friday."
    assert response["citations"]
    assert 0 <= response["confidence"] <= 1
    assert llm.last_prompt is not None
    assert "When should we ship v2?" in llm.last_prompt
    assert "session-a" in llm.last_prompt
    assert llm.last_schema == "chat"


async def test_chat_renders_canonical_context(llm) -> None:
    await run_chat(
        _chat_job(
            question="Summarize the session.",
            stage={"provider": "test-llm"},
            context=CONTEXT,
        )
    )
    assert "Release planning" in llm.last_prompt
    assert "Ship v2" in llm.last_prompt


async def test_missing_question_fails_structurally(llm) -> None:
    job = _chat_job(stage={"provider": "test-llm"}, context=CONTEXT)
    with pytest.raises(JobFailedError) as exc:
        await run_chat(job)
    assert exc.value.code == "CHAT_QUESTION_INVALID"


async def test_missing_context_fails_structurally(llm) -> None:
    job = _chat_job(question="What did I decide?")
    with pytest.raises(JobFailedError) as exc:
        await run_chat(job)
    assert exc.value.code == "CHAT_CONTEXT_INVALID"


async def test_invalid_response_is_retried_then_fails(llm) -> None:
    llm.response = {"unexpected": True}
    job = _chat_job(
        question="What did I decide?",
        stage={"provider": "test-llm"},
        context=CONTEXT,
    )
    with pytest.raises(JobFailedError) as exc:
        await run_chat(job)
    assert exc.value.code == "STAGE_OUTPUT_INVALID"


def test_process_job_dispatches_chat_kind(llm) -> None:
    store = get_store()
    job = store.create(
        _chat_job(
            question="What did I decide?",
            stage={"provider": "test-llm"},
            context=CONTEXT,
        )
    )

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.succeeded
    assert updated.result is not None
    assert updated.result["question"] == "What did I decide?"
    assert updated.result["session_id"] == "session-a"
    assert updated.result["prompt_versions"] == {"chat": 2}
    assert updated.result["response"]["answer"] == "We should ship v2 by Friday."


def test_process_job_unknown_chat_fails_structurally(llm) -> None:
    store = get_store()
    job = store.create(_chat_job(question="What did I decide?"))

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "CHAT_CONTEXT_INVALID"


def test_create_chat_job_via_api(llm) -> None:
    from app.main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    created = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": "u1"},
        json={
            "kind": "chat",
            "options": {
                "question": "What did I decide?",
                "stage": {"provider": "test-llm"},
                "context": CONTEXT,
            },
        },
    ).json()["data"]
    assert created["kind"] == "chat"
    assert created["status"] == "queued"

    job_id = created["id"]
    process_job(job_id)
    assert (
        client.get(f"/api/v1/jobs/{job_id}", headers={"X-User-Id": "u1"}).json()[
            "data"
        ]["status"]
        == "succeeded"
    )
