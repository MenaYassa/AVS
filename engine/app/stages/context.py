"""Stage configuration, token budget, and the shared stage context
(architecture §4.2).

`StageConfig` is resolved per stage from job options merged over engine
defaults. `TokenBudget` guards each stage's input prompt. `StageContext`
carries the canonical `InputDoc`, resolved prompt versions, the budget, and
the per-stage intermediates the orchestrator persists between stages.
"""

from __future__ import annotations

from typing import Any

from app.config import settings
from app.errors import JobFailedError
from app.inputs.base import InputDoc
from app.prompts.registry import PromptAsset
from pydantic import BaseModel, Field


class StageConfig(BaseModel):
    """Resolved config for a single stage run (§4.2 token budget handling)."""

    provider: str = "placeholder"
    model: str | None = None
    base_url: str | None = None
    temperature: float | None = None
    max_tokens: int | None = None

    @classmethod
    def from_options(
        cls, stage_name: str, options: dict[str, Any] | None, asset: PromptAsset
    ) -> "StageConfig":
        """Merge job options over engine + asset defaults.

        `options["stage"]` applies globally; `options["stages"][<name>]`
        overrides it for one stage. Example:
        `{"stage": {"provider": "openai", "model": "gpt-4o-mini"},
          "stages": {"segmentation": {"temperature": 0.0}}}`
        """
        merged: dict[str, Any] = {}
        global_cfg = (options or {}).get("stage") or {}
        specific = ((options or {}).get("stages") or {}).get(stage_name) or {}
        if isinstance(global_cfg, dict):
            merged.update(global_cfg)
        if isinstance(specific, dict):
            merged.update(specific)

        return cls(
            provider=merged.get("provider")
            or settings.default_llm_provider
            or "placeholder",
            model=merged.get("model") or settings.default_llm_model or None,
            base_url=merged.get("base_url") or None,
            temperature=(
                merged.get("temperature", settings.default_temperature)
                if "temperature" in merged
                else settings.default_temperature
            ),
            max_tokens=merged.get("max_tokens") or settings.max_output_tokens,
        )


class TokenBudget(BaseModel):
    """Coarse token accounting for stage prompts (chars/4 estimate)."""

    max_input_tokens: int = Field(ge=1)
    max_output_tokens: int = Field(ge=1)

    @staticmethod
    def estimate_tokens(text: str) -> int:
        return max(1, len(text) // 4)

    def check_input(self, prompt: str, *, stage: str) -> None:
        estimated = self.estimate_tokens(prompt)
        if estimated > self.max_input_tokens:
            raise JobFailedError(
                f"Stage {stage} input exceeds token budget",
                code="TOKEN_BUDGET_EXCEEDED",
                details={
                    "stage": stage,
                    "estimated_tokens": estimated,
                    "max_input_tokens": self.max_input_tokens,
                },
            )


class StageContext:
    """Shared carrier between stages; the orchestrator persists outputs."""

    def __init__(
        self,
        *,
        input_doc: InputDoc,
        prompt_versions: dict[str, int],
        budget: TokenBudget,
        memory: list[dict[str, Any]] | None = None,
    ) -> None:
        self.input_doc = input_doc
        self.prompt_versions = prompt_versions
        self.budget = budget
        self.intermediates: dict[str, Any] = {}

        # Opt-in related-session memory context (architecture §4.9); the
        # LLM stages that consume it render it source-tagged into their prompt.
        self.memory = memory or []

    def require(self, stage: str) -> dict[str, Any]:
        """Fetch a completed upstream stage output or raise a structured error."""
        if stage not in self.intermediates:
            raise JobFailedError(
                f"Stage dependency missing: {stage}",
                code="STAGE_DEPENDENCY",
                details={"stage": stage, "completed": sorted(self.intermediates)},
            )
        return self.intermediates[stage]
