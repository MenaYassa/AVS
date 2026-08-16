"""Knowledge extraction stage: title, summary, and typed items (§4.2)."""

from __future__ import annotations

import json
from typing import Any

from app.memory import render_memory_block
from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import (
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_TASK_EXTRACTION,
)
from pydantic import BaseModel, Field

ITEM_TYPES = (
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
PRIORITIES = ("low", "medium", "high")


class KnowledgeItem(BaseModel):
    type: str = Field(pattern="|".join(ITEM_TYPES))
    title: str = Field(min_length=1)
    description: str | None = None
    priority: str | None = Field(default=None, pattern="|".join(PRIORITIES))
    confidence: float = Field(ge=0.0, le=1.0)
    topic_position: int = Field(ge=0)


class KnowledgeExtractionOutput(BaseModel):
    title: str | None = None
    alternative_titles: list[str] = Field(default_factory=list)
    summary: str | None = None
    summary_confidence: float = Field(default=0.5, ge=0.0, le=1.0)
    items: list[KnowledgeItem] = Field(default_factory=list)


class KnowledgeExtractionStage(LLMStage):
    name = STAGE_KNOWLEDGE_EXTRACTION

    def render_user_prompt(self, ctx: StageContext) -> str:
        cleaned = ctx.require(STAGE_CLEANUP)["cleaned_text"]
        topics = ctx.require(STAGE_CLASSIFICATION)["topics"]
        tasks = ctx.require(STAGE_TASK_EXTRACTION)["tasks"]
        return self.asset.user_prompt_template.format(
            topics=json.dumps(topics, ensure_ascii=False),
            tasks=json.dumps(tasks, ensure_ascii=False),
            transcript=cleaned,
            memory=render_memory_block(ctx.memory),
        )

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return KnowledgeExtractionOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"knowledge_extraction: {exc}") from exc
