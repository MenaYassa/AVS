"""Stage bases + the malformed-output retry loop (architecture §4.2).

`LLMStage` renders a user prompt from its versioned asset, enforces the token
budget, asks the provider for structured JSON, and validates the result. A
malformed/invalid output triggers exactly one schema-retry with corrective
feedback, then a structured `STAGE_OUTPUT_INVALID` failure (§2.1).

`DeterministicStage` covers the validation stage, which assembles and checks
the canonical session without calling any LLM.
"""

from __future__ import annotations

from typing import Any, Protocol

from app.errors import JobFailedError
from app.prompts.registry import PromptAsset
from app.providers.base import LLMProvider, ProviderOutputError
from app.stages.context import StageConfig, StageContext, TokenBudget


class Stage(Protocol):
    """Single-responsibility, independently replaceable pipeline stage."""

    name: str

    async def run(self, ctx: StageContext) -> StageContext: ...


class StageOutputError(ValueError):
    """Structured stage output failed validation; retryable once."""


def _validation_failure(stage: str, attempts: int, error: Exception) -> JobFailedError:
    return JobFailedError(
        f"Stage {stage} produced invalid output after {attempts} attempt(s)",
        code="STAGE_OUTPUT_INVALID",
        details={"stage": stage, "attempts": attempts, "error": str(error)},
    )


async def complete_structured_with_retry(
    provider: LLMProvider,
    asset: PromptAsset,
    prompt: str,
    config: StageConfig,
    *,
    stage: str,
    validator: Any,
) -> dict[str, Any]:
    """Ask for structured JSON; one corrective retry on invalid output."""
    attempts = 0
    feedback: str | None = None
    while True:
        attempts += 1
        user_prompt = prompt if feedback is None else f"{prompt}\n\n{feedback}"
        try:
            parsed = await provider.complete_structured(
                user_prompt,
                asset.json_schema_ref,
                system_prompt=asset.system_prompt,
                model=config.model,
                temperature=config.temperature,
                max_tokens=config.max_tokens,
            )
            return validator(parsed)
        except (StageOutputError, ProviderOutputError) as exc:
            if attempts >= 2:
                raise _validation_failure(stage, attempts, exc) from exc
            feedback = (
                "Your previous output failed validation and was not accepted. "
                f"Return only valid JSON matching the requested schema. "
                f"Validation feedback: {exc}"
            )
        except (TypeError, ValueError) as exc:  # noqa: BLE001
            raise _validation_failure(stage, attempts, exc) from exc


class LLMStage:
    """Base for the six LLM-backed pipeline stages."""

    name: str

    def __init__(
        self,
        *,
        asset: PromptAsset,
        config: StageConfig,
        provider: LLMProvider,
        budget: TokenBudget,
    ) -> None:
        self.asset = asset
        self.config = config
        self.provider = provider
        self.budget = budget

    def render_user_prompt(self, ctx: StageContext) -> str:
        raise NotImplementedError

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        """Normalize/validate provider output; raise StageOutputError."""
        raise NotImplementedError

    async def run(self, ctx: StageContext) -> StageContext:
        prompt = self.render_user_prompt(ctx)
        self.budget.check_input(prompt, stage=self.name)
        output = await complete_structured_with_retry(
            self.provider,
            self.asset,
            prompt,
            self.config,
            stage=self.name,
            validator=self.validate_output,
        )
        ctx.intermediates[self.name] = output
        return ctx


class DeterministicStage:
    """Base for non-LLM stages (currently validation, §4.2 step 7)."""

    name: str

    def __init__(self, *, asset: PromptAsset, budget: TokenBudget) -> None:
        self.asset = asset
        self.budget = budget

    def build(self, ctx: StageContext) -> dict[str, Any]:
        raise NotImplementedError

    async def run(self, ctx: StageContext) -> StageContext:
        ctx.intermediates[self.name] = self.build(ctx)
        return ctx
