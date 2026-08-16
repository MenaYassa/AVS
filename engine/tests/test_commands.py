"""AI command bus tests (architecture §4.11, spec §23).

Exercises the command runner, the worker dispatch path, and the API surface
for `kind: command` jobs. Provider output is faked; the runner's schema
validation is the unit under test alongside the job plumbing.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.commands.names import COMMAND_NAMES
from app.errors import JobFailedError
from app.models import Job, JobKind, JobStatus
from app.providers.registry import register_llm, unregister_llm
from app.store import get_store
from app.workers.orchestrator import process_job, run_command

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


class FakeCommandLLM:
    """Returns a schema-valid Draft on every call, capturing the last prompt."""

    def __init__(self, draft: dict[str, object]) -> None:
        self.draft = draft
        self.last_prompt: str | None = None
        self.last_schema: str | None = None

    async def complete(self, *args, **kwargs) -> str:
        return ""

    async def complete_structured(self, prompt, json_schema, **kwargs):
        self.last_prompt = prompt
        self.last_schema = str(json_schema)
        return self.draft


def _command_job(**options) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=JobKind.command,
        status=JobStatus.queued,
        input_ref=None,
        options=options,
        created_at=now,
        updated_at=now,
    )


@pytest.fixture
def llm():
    fake = FakeCommandLLM(
        {"title": "Extracted tasks", "body": "From the session.", "items": []}
    )
    register_llm("test-llm", fake)
    yield fake
    unregister_llm("test-llm")


async def test_every_command_runs_and_produces_a_valid_draft(llm) -> None:
    for command in COMMAND_NAMES:
        result = await run_command(
            _command_job(
                command=command,
                stage={"provider": "test-llm"},
                context=CONTEXT,
            )
        )
        assert result["command"] == command
        assert result["prompt_versions"] == {command: 1}
        draft = result["draft"]
        assert draft["title"]
        assert "body" in draft
        assert "items" in draft
        assert llm.last_prompt is not None
        assert "session-a" in llm.last_prompt
        assert llm.last_schema == "draft"


async def test_command_renders_context_and_params(llm) -> None:
    context = {**CONTEXT, "params": {"recipient": "Team"}}
    await run_command(
        _command_job(
            command="email",
            stage={"provider": "test-llm"},
            context=context,
        )
    )
    assert '"recipient": "Team"' in llm.last_prompt
    assert "Release planning" in llm.last_prompt


async def test_command_with_structured_items_keeps_them(llm) -> None:
    llm.draft = {
        "title": "Extracted tasks",
        "body": "",
        "items": [
            {"title": "Ship v2", "type": "task", "priority": "high", "confidence": 0.9}
        ],
    }
    result = await run_command(
        _command_job(
            command="extract_tasks",
            stage={"provider": "test-llm"},
            context=CONTEXT,
        )
    )
    assert result["draft"]["items"] == [
        {
            "title": "Ship v2",
            "type": "task",
            "priority": "high",
            "confidence": 0.9,
            "body": "",
        }
    ]


async def test_unknown_command_fails_structurally(llm) -> None:
    job = _command_job(command="ghost_command", context=CONTEXT)
    with pytest.raises(JobFailedError) as exc:
        await run_command(job)
    assert exc.value.code == "UNKNOWN_COMMAND"
    assert exc.value.details["command"] == "ghost_command"


async def test_missing_context_fails_structurally(llm) -> None:
    job = _command_job(command="email")
    with pytest.raises(JobFailedError) as exc:
        await run_command(job)
    assert exc.value.code == "COMMAND_CONTEXT_INVALID"


async def test_invalid_draft_is_retried_then_fails(llm) -> None:
    llm.draft = {"unexpected": True}
    job = _command_job(command="email", stage={"provider": "test-llm"}, context=CONTEXT)
    with pytest.raises(JobFailedError) as exc:
        await run_command(job)
    assert exc.value.code == "STAGE_OUTPUT_INVALID"


def test_process_job_dispatches_command_kind(llm) -> None:
    store = get_store()
    job = store.create(
        _command_job(
            command="shorten_summary",
            stage={"provider": "test-llm"},
            context=CONTEXT,
        )
    )

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.succeeded
    assert updated.result is not None
    assert updated.result["command"] == "shorten_summary"
    assert updated.result["session_id"] == "session-a"
    assert updated.result["draft"]["title"] == "Extracted tasks"
    assert updated.result["prompt_versions"] == {"shorten_summary": 1}


def test_process_job_unknown_command_fails_structurally(llm) -> None:
    store = get_store()
    job = store.create(_command_job(command="nope", context=CONTEXT))

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "UNKNOWN_COMMAND"


def test_create_command_job_via_api(llm) -> None:
    from app.main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    created = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": "u1"},
        json={
            "kind": "command",
            "options": {
                "command": "email",
                "stage": {"provider": "test-llm"},
                "context": CONTEXT,
            },
        },
    ).json()["data"]
    assert created["kind"] == "command"
    assert created["status"] == "queued"

    job_id = created["id"]
    process_job(job_id)
    assert (
        client.get(f"/api/v1/jobs/{job_id}", headers={"X-User-Id": "u1"}).json()[
            "data"
        ]["status"]
        == "succeeded"
    )
