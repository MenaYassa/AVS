"""Segmentation stage: split cleaned transcript into topical segments (§4.2)."""

from __future__ import annotations

from typing import Any

from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLEANUP, STAGE_SEGMENTATION
from pydantic import BaseModel, Field


class Segment(BaseModel):
    position: int = Field(ge=0)
    title: str = Field(min_length=1)
    text: str = Field(min_length=1)


class SegmentationOutput(BaseModel):
    segments: list[Segment] = Field(min_length=1)


class SegmentationStage(LLMStage):
    name = STAGE_SEGMENTATION

    def render_user_prompt(self, ctx: StageContext) -> str:
        cleaned = ctx.require(STAGE_CLEANUP)["cleaned_text"]
        return self.asset.user_prompt_template.format(transcript=cleaned)

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            segments = SegmentationOutput.model_validate(parsed)
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"segmentation: {exc}") from exc
        positions = [s.position for s in segments.segments]
        if positions != sorted(positions) or len(set(positions)) != len(positions):
            raise StageOutputError(
                f"segmentation: positions must be strictly increasing, got {positions}"
            )
        return segments.model_dump()
