"""AI chat runner (architecture §4.11, spec §23).

A chat job (`JobKind.chat`) carries the user's question and the session's
canonical content in `options.context`; the runner renders the chat prompt
asset over that context, asks the configured LLM for a grounded answer,
validates it against `chat.schema.json`, and returns the result.
"""

from __future__ import annotations

import json
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.config import settings
from app.errors import JobFailedError
from app.memory import normalize_memory, render_memory_block
from app.models import Job
from app.prompts.registry import get_prompt_registry
from app.providers.registry import get_llm
from app.schemas import chat_schema
from app.stages.base import StageOutputError, complete_structured_with_retry
from app.stages.context import StageConfig, TokenBudget

CHAT_PROMPT_NAME = "chat"

_MAX_CONTEXT_TRANSCRIPT_CHARS = 60_000


class ChatResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    answer: str = Field(min_length=1)
    citations: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)


def render_chat_context(context: dict[str, Any] | None) -> str:
    """Compact, prompt-shaped JSON of the session content for chat."""
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
    for key in ("tags", "entities", "topics"):
        value = context.get(key) if context else None
        if value:
            payload[key] = value

    return json.dumps(payload, ensure_ascii=False, indent=2)


def _require_context(options: dict[str, Any]) -> dict[str, Any]:
    context = options.get("context")
    if not isinstance(context, dict):
        raise JobFailedError(
            "A chat job needs options.context with the session content",
            code="CHAT_CONTEXT_INVALID",
            details={"got": type(context).__name__ if context is not None else None},
        )
    return context


def _require_question(options: dict[str, Any]) -> str:
    question = options.get("question")
    if not isinstance(question, str) or not question.strip():
        raise JobFailedError(
            "A chat job needs options.question with the user's question",
            code="CHAT_QUESTION_INVALID",
        )
    return question.strip()


def _validate_chat_response(parsed: dict[str, Any]) -> dict[str, Any]:
    """Validate the provider's response against pydantic + the shared JSON schema."""
    from jsonschema import ValidationError as JsonSchemaError

    try:
        from app.schemas import validate_against_schema

        validate_against_schema(parsed, chat_schema())
    except JsonSchemaError as exc:
        raise StageOutputError(f"chat: {exc}") from exc
    try:
        response = ChatResponse.model_validate(parsed)
    except Exception as exc:  # noqa: BLE001
        raise StageOutputError(f"chat: {exc}") from exc
    return {"response": response.model_dump()}


async def run_chat(job: Job) -> dict[str, Any]:
    """Execute a chat job; returns question, session_id, prompt_versions, response."""
    options = job.options or {}
    question = _require_question(options)
    context = _require_context(options)
    memory = normalize_memory(options.get("memory"))

    prompt_registry = get_prompt_registry()
    requested = job.prompt_versions or {}
    version = requested.get(CHAT_PROMPT_NAME)
    asset = (
        prompt_registry.get(CHAT_PROMPT_NAME, int(version))
        if version is not None
        else prompt_registry.latest(CHAT_PROMPT_NAME)
    )

    config = StageConfig.from_options("chat", options, asset)
    budget = TokenBudget(
        max_input_tokens=settings.max_input_tokens,
        max_output_tokens=settings.max_output_tokens,
    )
    prompt = asset.user_prompt_template.format(
        question=question,
        context=render_chat_context(context),
        memory=render_memory_block(memory),
    )
    budget.check_input(prompt, stage="chat")

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
        stage="chat",
        validator=_validate_chat_response,
    )

    return {
        "question": question,
        "session_id": context.get("session_id"),
        "prompt_versions": {CHAT_PROMPT_NAME: asset.version},
        "response": output["response"],
    }
