"""Tags stage: reusable, searchable session tags (architecture §4.2, spec §19).

A small set of descriptive tags that can be reused across sessions for
organization. Output feeds the canonical session's `tags` field; the app
surfaces them as auto-generated tags on the session.
"""

from __future__ import annotations

from typing import Any

from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLEANUP, STAGE_TAGS
from pydantic import BaseModel, Field


class Tag(BaseModel):
    name: str = Field(min_length=1)
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class TagsOutput(BaseModel):
    tags: list[Tag] = Field(default_factory=list, max_length=20)


class TagsStage(LLMStage):
    name = STAGE_TAGS

    def render_user_prompt(self, ctx: StageContext) -> str:
        cleaned = ctx.require(STAGE_CLEANUP)["cleaned_text"]
        return self.asset.user_prompt_template.format(transcript=cleaned)

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return TagsOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"tags: {exc}") from exc
