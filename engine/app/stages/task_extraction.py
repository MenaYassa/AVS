"""Task extraction stage: actionable commitments with priority/due (§4.2)."""

from __future__ import annotations

from typing import Any

from app.memory import render_memory_block
from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLEANUP, STAGE_TASK_EXTRACTION
from pydantic import BaseModel, Field

TASK_TYPES = ("action", "follow_up", "decision", "reminder", "waiting_on")
PRIORITIES = ("low", "medium", "high")


class Task(BaseModel):
    title: str = Field(min_length=1)
    type: str = Field(pattern="|".join(TASK_TYPES))
    priority: str = Field(pattern="|".join(PRIORITIES))
    due: str | None = None
    confidence: float = Field(ge=0.0, le=1.0)


class TaskExtractionOutput(BaseModel):
    tasks: list[Task] = Field(default_factory=list)


class TaskExtractionStage(LLMStage):
    name = STAGE_TASK_EXTRACTION

    def render_user_prompt(self, ctx: StageContext) -> str:
        cleaned = ctx.require(STAGE_CLEANUP)["cleaned_text"]
        return self.asset.user_prompt_template.format(
            transcript=cleaned, memory=render_memory_block(ctx.memory)
        )

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return TaskExtractionOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"task_extraction: {exc}") from exc
