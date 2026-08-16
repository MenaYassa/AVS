"""Cleanup stage: transcription artifacts -> clean, faithful text (§4.2)."""

from __future__ import annotations

from typing import Any

from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLEANUP
from pydantic import BaseModel, Field


class CleanupOutput(BaseModel):
    cleaned_text: str = Field(min_length=1)
    original_text: str


class CleanupStage(LLMStage):
    name = STAGE_CLEANUP

    def render_user_prompt(self, ctx: StageContext) -> str:
        return self.asset.user_prompt_template.format(transcript=ctx.input_doc.text)

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return CleanupOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"cleanup: {exc}") from exc
