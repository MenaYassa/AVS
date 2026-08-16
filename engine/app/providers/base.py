"""LLM provider contracts (architecture §4.4).

Adapters implement `LLMProvider`. `complete_structured` is the workhorse for
pipeline stages: it returns parsed JSON. Providers may use `json_schema` for
native schema support (e.g. `response_format`); stages also validate output
locally, so providers that ignore it still produce schema-safe results.
"""

from __future__ import annotations

from typing import Any, Protocol

from pydantic import BaseModel, Field


class Message(BaseModel):
    role: str = Field(pattern="^(system|user|assistant)$")
    content: str


class LLMProvider(Protocol):
    """Chat completion + structured output behind every LLM adapter."""

    async def complete(
        self,
        messages: list[Message],
        *,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str: ...

    async def complete_structured(
        self,
        prompt: str,
        json_schema: str | dict[str, Any] | None,
        *,
        system_prompt: str | None = None,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> dict[str, Any]: ...


class ProviderOutputError(ValueError):
    """Provider returned output that could not be parsed/used as structured JSON.

    Treated as retryable by the stage runner (one schema-retry, then a
    structured `STAGE_OUTPUT_INVALID` failure, §2.1).
    """
