"""AI command bus runner (architecture §4.11, spec §23).

A command job (`JobKind.command`) carries the command name and the session's
canonical content in `options.context`; the runner renders the command's
versioned prompt asset over that context, asks the configured LLM for a Draft
(`draft.schema.json`), validates it against the shared schema, and returns the
draft as the job result. Output is always an *editable draft* — the client owns
deciding whether/how to apply it back into a session.

The runner never touches the pipeline stages: commands are single-shot prompts
over already-analyzed content, with the same immutability (§4.3), token budget,
and one-schema-retry guarantees as the stages.
"""

from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.commands.names import COMMAND_NAMES
from app.config import settings
from app.errors import JobFailedError
from app.models import Job
from app.prompts.registry import get_prompt_registry
from app.providers.registry import get_llm
from app.schemas import draft_schema
from app.stages.base import StageOutputError, complete_structured_with_retry
from app.stages.context import StageConfig, TokenBudget

# Canonical session item types (`session.schema.json`).
_ITEM_TYPES = (
    "idea",
    "task",
    "decision",
    "question",
    "problem",
    "risk",
    "goal",
    "event",
    "reminder",
    "reference",
    "observation",
    "opportunity",
    "actionItem",
)

# Hard cap on the transcript slice rendered into a command prompt. The token
# budget is the real guard; this keeps prompt size predictable.
_MAX_CONTEXT_TRANSCRIPT_CHARS = 60_000


class DraftItem(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1)
    body: str = ""
    type: str | None = Field(default=None, pattern="|".join(_ITEM_TYPES))
    priority: str | None = Field(default=None, pattern="^(low|medium|high)$")
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


class Draft(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1)
    body: str = ""
    items: list[DraftItem] = Field(default_factory=list)


def _item_type(value: Any) -> str | None:
    return value if value in _ITEM_TYPES else None


def render_session_context(context: dict[str, Any] | None) -> str:
    """Compact, prompt-shaped JSON of the session content a command works on.

    Only non-empty fields survive, and the transcript is capped so prompts stay
    predictable. `params` carry command-specific knobs the user set in the UI
    (e.g. recipient/audience for `email`).
    """
    transcript = context.get("transcript") if context else None
    if isinstance(transcript, str):
        transcript = transcript[:_MAX_CONTEXT_TRANSCRIPT_CHARS]

    payload: dict[str, Any] = {}
    if context:
        payload["session_id"] = context.get("session_id")
    for key in ("title", "summary", "language"):
        value = context.get(key) if context else None
        if value:
            payload[key] = value
    if transcript:
        payload["transcript"] = transcript
    for key in ("tags", "entities", "topics", "params"):
        value = context.get(key) if context else None
        if value:
            payload[key] = value

    return json.dumps(payload, ensure_ascii=False, indent=2)


def _require_context(options: dict[str, Any]) -> dict[str, Any]:
    context = options.get("context")
    if not isinstance(context, dict):
        raise JobFailedError(
            "A command job needs options.context with the session content",
            code="COMMAND_CONTEXT_INVALID",
            details={"got": type(context).__name__ if context is not None else None},
        )
    return context


def _validate_draft(parsed: dict[str, Any]) -> dict[str, Any]:
    """Validate the provider's Draft against pydantic + the shared JSON schema.

    The JSON Schema contract (`draft.schema.json`) is the authority, mirroring
    how the validation stage checks canonical sessions (§5.2).
    """
    from jsonschema import ValidationError as JsonSchemaError

    try:
        from app.schemas import validate_against_schema

        validate_against_schema(parsed, draft_schema())
    except JsonSchemaError as exc:
        raise StageOutputError(f"command: {exc}") from exc
    try:
        draft = Draft.model_validate(parsed)
    except Exception as exc:  # noqa: BLE001
        raise StageOutputError(f"command: {exc}") from exc
    return {"draft": draft.model_dump()}


async def run_command(job: Job) -> dict[str, Any]:
    """Execute a command job and return `{command, session_id, prompt_versions,
    draft}` — the job's `result`."""
    options = job.options or {}
    command = options.get("command")
    if command not in COMMAND_NAMES:
        raise JobFailedError(
            f"Unknown AI command: {command!r}",
            code="UNKNOWN_COMMAND",
            details={"command": command, "known": list(COMMAND_NAMES)},
        )
    context = _require_context(options)

    prompt_registry = get_prompt_registry()
    requested = job.prompt_versions or {}
    version = requested.get(command)
    asset = (
        prompt_registry.get(command, int(version))
        if version is not None
        else prompt_registry.latest(command)
    )

    config = StageConfig.from_options(command, options, asset)
    budget = TokenBudget(
        max_input_tokens=settings.max_input_tokens,
        max_output_tokens=settings.max_output_tokens,
    )
    prompt = asset.user_prompt_template.format(context=render_session_context(context))
    budget.check_input(prompt, stage=command)

    provider = get_llm(
        config.provider,
        user_id=job.user_id,
        base_url=config.base_url,
        model=config.model,
    )
    output = await complete_structured_with_retry(
        provider,
        asset,
        prompt,
        config,
        stage=command,
        validator=_validate_draft,
    )

    return {
        "command": command,
        "session_id": context.get("session_id"),
        "prompt_versions": {command: asset.version},
        "draft": output["draft"],
    }
