"""Classification stage: name the topic of each segment (§4.2)."""

from __future__ import annotations

import json
from typing import Any

from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLASSIFICATION, STAGE_SEGMENTATION
from pydantic import BaseModel, Field


class Topic(BaseModel):
    position: int = Field(ge=0)
    title: str = Field(min_length=1)
    description: str = ""
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class ClassificationOutput(BaseModel):
    topics: list[Topic] = Field(min_length=1)


class ClassificationStage(LLMStage):
    name = STAGE_CLASSIFICATION

    def render_user_prompt(self, ctx: StageContext) -> str:
        segments = ctx.require(STAGE_SEGMENTATION)["segments"]
        return self.asset.user_prompt_template.format(
            segments=json.dumps(segments, ensure_ascii=False)
        )

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return ClassificationOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"classification: {exc}") from exc
