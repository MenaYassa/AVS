"""Stage unit tests: StageConfig, TokenBudget, LLM stage, schema-retry
(architecture §4.2, §2.1)."""

from __future__ import annotations

import pytest
from app.errors import JobFailedError
from app.prompts.registry import get_prompt_registry
from app.providers.base import ProviderOutputError
from app.stages.base import StageOutputError, complete_structured_with_retry
from app.stages.cleanup import CleanupStage
from app.stages.context import StageConfig, TokenBudget
from app.stages.names import STAGE_CLEANUP, STAGE_TAGS
from app.stages.tags import TagsStage

ASSETS = get_prompt_registry()


def test_token_budget_estimates_chars_over_four() -> None:
    budget = TokenBudget(max_input_tokens=4, max_output_tokens=4)
    assert budget.estimate_tokens("abcdefgh") == 2
    assert budget.estimate_tokens("") == 1


def test_token_budget_check_input_rejects_overflow() -> None:
    budget = TokenBudget(max_input_tokens=2, max_output_tokens=4)
    with pytest.raises(JobFailedError) as exc:
        budget.check_input("x" * 40, stage="cleanup")
    assert exc.value.code == "TOKEN_BUDGET_EXCEEDED"
    assert exc.value.details["stage"] == "cleanup"


def test_stage_config_merges_global_and_specific_options() -> None:
    asset = ASSETS.latest(STAGE_CLEANUP)
    config = StageConfig.from_options(
        STAGE_CLEANUP,
        options={
            "stage": {"provider": "openai", "model": "gpt-4o-mini", "max_tokens": 500},
            "stages": {STAGE_CLEANUP: {"temperature": 0.0}},
        },
        asset=asset,
    )

    assert config.provider == "openai"
    assert config.model == "gpt-4o-mini"
    assert config.max_tokens == 500
    assert config.temperature == 0.0


def test_stage_config_defaults_to_placeholder() -> None:
    config = StageConfig.from_options(STAGE_CLEANUP, None, ASSETS.latest(STAGE_CLEANUP))
    assert config.provider == "placeholder"
    assert config.temperature is not None


class _ScriptedProvider:
    """Returns queued outputs / raises per call; used for retry semantics."""

    def __init__(self, *responses) -> None:
        self.responses = list(responses)
        self.calls = 0

    async def complete_structured(self, *args, **kwargs):
        self.calls += 1
        response = self.responses[self.calls - 1]
        if isinstance(response, Exception):
            raise response
        return response


def _make_cleanup_stage(provider) -> CleanupStage:
    asset = ASSETS.latest(STAGE_CLEANUP)
    return CleanupStage(
        asset=asset,
        config=StageConfig(provider="scripted"),
        provider=provider,
        budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
    )


async def test_cleanup_retries_once_on_invalid_output() -> None:
    provider = _ScriptedProvider(
        {"unexpected": True},
        {"cleaned_text": "hello", "original_text": "uh hello"},
    )
    stage = _make_cleanup_stage(provider)

    result = await complete_structured_with_retry(
        provider,
        stage.asset,
        "prompt",
        stage.config,
        stage=stage.name,
        validator=stage.validate_output,
    )
    assert result == {"cleaned_text": "hello", "original_text": "uh hello"}
    assert provider.calls == 2


async def test_cleanup_fails_structurally_after_two_invalid_attempts() -> None:
    provider = _ScriptedProvider({"unexpected": True}, {"unexpected": True})
    stage = _make_cleanup_stage(provider)

    with pytest.raises(JobFailedError) as exc:
        await complete_structured_with_retry(
            provider,
            stage.asset,
            "prompt",
            stage.config,
            stage=stage.name,
            validator=stage.validate_output,
        )
    assert exc.value.code == "STAGE_OUTPUT_INVALID"
    assert exc.value.details["stage"] == "cleanup"
    assert exc.value.details["attempts"] == 2


async def test_retry_recovers_from_provider_output_error() -> None:
    provider = _ScriptedProvider(
        ProviderOutputError("not json"),
        {"cleaned_text": "ok", "original_text": "ok"},
    )
    stage = _make_cleanup_stage(provider)

    result = await complete_structured_with_retry(
        provider,
        stage.asset,
        "prompt",
        stage.config,
        stage=stage.name,
        validator=stage.validate_output,
    )
    assert result["cleaned_text"] == "ok"
    assert provider.calls == 2


async def test_stage_output_error_is_retryable_marker() -> None:
    with pytest.raises(StageOutputError):
        _make_cleanup_stage(_ScriptedProvider()).validate_output({"cleaned_text": ""})


def _make_tags_stage(provider) -> TagsStage:
    asset = ASSETS.latest(STAGE_TAGS)
    return TagsStage(
        asset=asset,
        config=StageConfig.from_options(STAGE_TAGS, None, asset),
        provider=provider,
        budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
    )


def test_tags_stage_renders_prompt_with_transcript() -> None:
    from app.inputs.base import InputDoc
    from app.stages.context import StageContext

    ctx = StageContext(
        input_doc=InputDoc(kind="transcript", text="hello"),
        prompt_versions={STAGE_TAGS: 1},
        budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
    )
    ctx.intermediates[STAGE_CLEANUP] = {"cleaned_text": "We should ship v2 by Friday."}

    prompt = _make_tags_stage(_ScriptedProvider()).render_user_prompt(ctx)

    assert "We should ship v2 by Friday." in prompt
    assert 'json_schema_ref' not in prompt  # instruction lives in the asset


def test_tags_stage_validates_output() -> None:
    stage = _make_tags_stage(_ScriptedProvider())
    result = stage.validate_output(
        {"tags": [{"name": "release planning", "confidence": 0.9}]}
    )
    assert result == {"tags": [{"name": "release planning", "confidence": 0.9}]}


def test_tags_stage_rejects_invalid_output() -> None:
    with pytest.raises(StageOutputError):
        _make_tags_stage(_ScriptedProvider()).validate_output(
            {"tags": [{"name": ""}]}
        )
