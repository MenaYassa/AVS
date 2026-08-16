"""Cleanup-preserves-meaning golden tests (§2.5).

Hermetic interpretation: the shipped cleanup prompt is the contract that must
enforce meaning preservation, and `tests/fixtures/cleanup/*.json` are recorded
goldens of the expected behavior. These tests check (a) the shipped prompt
still carries the preservation constraints, (b) every golden satisfies the
deterministic meaning-preservation invariants (numbers, negations, names kept;
filler removed), and (c) the `CleanupStage` reproduces each golden end-to-end
against the pinned asset. Live quality still needs recorded LLM evaluation,
which the golden fixtures are designed to seed.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from app.inputs.base import InputDoc
from app.prompts.registry import get_prompt_registry
from app.stages.cleanup import CleanupStage
from app.stages.context import StageConfig, StageContext, TokenBudget
from app.stages.names import STAGE_CLEANUP

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "cleanup"
ASSETS = get_prompt_registry()

NEGATIONS = {
    "not",
    "never",
    "no",
    "won't",
    "can't",
    "don't",
    "doesn't",
    "isn't",
    "aren't",
    "didn't",
    "haven't",
    "hasn't",
}
FILLER_WORDS = {"um", "uh", "hmm", "kinda", "sorta", "basically", "okay"}
FILLER_PHRASES = ("you know", "i mean", "like i said")
# Sentence-start words that are capitalized in the raw transcript but carry no
# entity meaning; excluded from the name-preservation check.
_CAPITALIZED_STOP = {
    "the",
    "a",
    "an",
    "we",
    "i",
    "so",
    "but",
    "and",
    "then",
    "okay",
    "actually",
    "well",
    "um",
    "uh",
}


def _load_goldens() -> list[dict[str, str]]:
    return [json.loads(p.read_text()) for p in sorted(FIXTURES.glob("*.json"))]


def _tokens(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9']+", text.lower()))


def _number_tokens(text: str) -> set[str]:
    return {t.lower() for t in re.findall(r"\b[a-z]*\d[a-z0-9]*\b", text)}


def _capitalized(text: str) -> set[str]:
    return {t.lower() for t in re.findall(r"\b[A-Z][a-zA-Z0-9]*\b", text)}


def _assert_meaning_preserved(raw: str, cleaned: str) -> None:
    cleaned_tokens = _tokens(cleaned)
    lost_numbers = _number_tokens(raw) - cleaned_tokens
    assert not lost_numbers, f"cleanup dropped number(s): {sorted(lost_numbers)}"

    lost_negations = {n for n in NEGATIONS if n in _tokens(raw)} - cleaned_tokens
    assert not lost_negations, f"cleanup flipped a negation: {sorted(lost_negations)}"

    names = _capitalized(raw) - _CAPITALIZED_STOP
    lost_names = names - cleaned_tokens
    assert not lost_names, f"cleanup dropped name(s): {sorted(lost_names)}"


def _assert_filler_removed(cleaned: str) -> None:
    cleaned_tokens = _tokens(cleaned)
    leftover = cleaned_tokens & FILLER_WORDS
    assert not leftover, f"filler left in cleaned text: {sorted(leftover)}"
    lowered = cleaned.lower()
    for phrase in FILLER_PHRASES:
        assert phrase not in lowered, f"filler phrase left in cleaned text: {phrase!r}"


@pytest.fixture(scope="module")
def goldens() -> list[dict[str, str]]:
    return _load_goldens()


class TestCleanupGoldenInvariants:
    def test_fixtures_cover_meaning_preservation_cases(self, goldens) -> None:
        assert {g["name"] for g in goldens} >= {"meeting", "technical", "unclear"}

    @pytest.mark.parametrize("golden", _load_goldens(), ids=lambda g: g["name"])
    def test_golden_preserves_meaning(self, golden) -> None:
        _assert_meaning_preserved(golden["raw"], golden["cleaned"])

    @pytest.mark.parametrize("golden", _load_goldens(), ids=lambda g: g["name"])
    def test_golden_removes_filler(self, golden) -> None:
        _assert_filler_removed(golden["cleaned"])


class TestShippedPromptConstraints:
    def test_cleanup_prompt_requires_preserving_facts(self) -> None:
        asset = ASSETS.latest(STAGE_CLEANUP)
        combined = f"{asset.system_prompt}\n{asset.user_prompt_template}".lower()
        for requirement in ("preserve every fact", "never change meaning"):
            assert requirement in combined, (
                f"cleanup prompt dropped preservation constraint: {requirement!r}"
            )

    def test_cleanup_prompt_handles_unclear_regions(self) -> None:
        asset = ASSETS.latest(STAGE_CLEANUP)
        assert "[unclear]" in asset.system_prompt

    def test_cleanup_prompt_mirrors_golden_instruction(self) -> None:
        asset = ASSETS.latest(STAGE_CLEANUP)
        # The template must instruct removal of exactly the artifact classes the
        # goldens exercise (filler words, restarts, duplications).
        combined = f"{asset.system_prompt}\n{asset.user_prompt_template}".lower()
        for artifact in ("filler", "disfluenc"):
            assert artifact in combined


class _ScriptedCleanupProvider:
    def __init__(self, cleaned_text: str, original_text: str) -> None:
        self.cleaned_text = cleaned_text
        self.original_text = original_text
        self.prompt: str | None = None
        self.system_prompt: str | None = None

    async def complete_structured(self, prompt, json_schema, **kwargs):
        self.prompt = prompt
        self.system_prompt = kwargs.get("system_prompt")
        return {"cleaned_text": self.cleaned_text, "original_text": self.original_text}


class TestCleanupStageEndToEnd:
    @pytest.mark.parametrize("golden", _load_goldens(), ids=lambda g: g["name"])
    @pytest.mark.asyncio
    async def test_stage_reproduces_golden_from_pinned_asset(self, golden) -> None:
        provider = _ScriptedCleanupProvider(
            golden["cleaned"],
            golden["original"] if "original" in golden else golden["raw"],
        )
        stage = CleanupStage(
            asset=ASSETS.latest(STAGE_CLEANUP),
            config=StageConfig(provider="scripted"),
            provider=provider,
            budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
        )
        ctx = StageContext(
            input_doc=InputDoc(
                kind="voice", text=golden["raw"], meta={"language": "en"}
            ),
            prompt_versions={"cleanup": 1},
            budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
        )

        result = await stage.run(ctx)

        output = ctx.intermediates[STAGE_CLEANUP]
        assert output["cleaned_text"] == golden["cleaned"]
        assert output["original_text"] == golden["raw"]
        assert result.intermediates[STAGE_CLEANUP] == output

    @pytest.mark.asyncio
    async def test_rendered_prompt_embeds_transcript_and_constraints(self) -> None:
        provider = _ScriptedCleanupProvider("cleaned", "raw")
        stage = CleanupStage(
            asset=ASSETS.latest(STAGE_CLEANUP),
            config=StageConfig(provider="scripted"),
            provider=provider,
            budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
        )
        ctx = StageContext(
            input_doc=InputDoc(kind="voice", text="uh raw transcript", meta={}),
            prompt_versions={"cleanup": 1},
            budget=TokenBudget(max_input_tokens=10_000, max_output_tokens=10_000),
        )

        await stage.run(ctx)

        assert provider.prompt is not None
        assert "uh raw transcript" in provider.prompt
        assert "never change meaning" in provider.prompt.lower()
        assert provider.system_prompt == ASSETS.latest(STAGE_CLEANUP).system_prompt
