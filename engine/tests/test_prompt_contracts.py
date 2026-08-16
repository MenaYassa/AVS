"""Prompt contract tests (architecture §4.3).

Pinned fixtures per `(stage, version)`: `tests/fixtures/prompts/` is a
byte-for-byte golden copy of every shipped prompt asset. A version bump
therefore means adding a new fixture file — and the git diff of that file *is*
the reviewable prompt change. Editing a pinned version in place fails here,
enforcing the "old versions are immutable" rule.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from app.commands.chat_runner import CHAT_PROMPT_NAME
from app.commands.names import COMMAND_NAMES
from app.prompts.registry import get_prompt_registry
from app.stages.names import PIPELINE_STAGES

PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
PINNED_DIR = Path(__file__).resolve().parent / "fixtures" / "prompts"

_KNOWN_ASSETS = (
    frozenset(PIPELINE_STAGES)
    | frozenset(COMMAND_NAMES)
    | frozenset({CHAT_PROMPT_NAME})
)

_ASSET_FILENAME = re.compile(r"^(?P<stage>[a-z_]+)\.(?P<version>\d+)\.json$")


def _files(directory: Path) -> list[Path]:
    return sorted(directory.glob("*.json"))


def _asset_version(path: Path) -> tuple[str, int]:
    match = _ASSET_FILENAME.match(path.name)
    assert match is not None, f"misnamed prompt asset: {path.name}"
    return match.group("stage"), int(match.group("version"))


def test_shipped_prompts_match_pinned_contract_exactly() -> None:
    shipped = _files(PROMPTS_DIR)
    pinned = _files(PINNED_DIR)

    assert [p.name for p in shipped] == [p.name for p in pinned], (
        "prompt asset filenames drifted from tests/fixtures/prompts/; a version "
        "bump must add a new pinned fixture (the diff is the reviewable change)"
    )
    for source, fixture in zip(shipped, pinned):
        assert source.read_bytes() == fixture.read_bytes(), (
            f"prompt asset {source.name} was edited in place; old prompt versions "
            "are immutable — bump the version and add a new pinned fixture instead"
        )


def test_every_stage_and_command_has_a_shipped_prompt() -> None:
    shipped = {_asset_version(p)[0] for p in _files(PROMPTS_DIR)}
    assert shipped == _KNOWN_ASSETS


def test_asset_filenames_are_consistent_with_content() -> None:
    for path in _files(PROMPTS_DIR):
        stage, version = _asset_version(path)
        data = json.loads(path.read_text())
        assert data["name"] == stage
        assert data["version"] == version
        if stage in COMMAND_NAMES:
            assert data["json_schema_ref"] == "draft"
        elif stage == CHAT_PROMPT_NAME:
            assert data["json_schema_ref"] == CHAT_PROMPT_NAME
        else:
            assert data["json_schema_ref"] == f"stage.{stage}"


def test_prompt_versions_are_contiguous_from_one() -> None:
    versions: dict[str, list[int]] = {}
    for path in _files(PROMPTS_DIR):
        stage, version = _asset_version(path)
        versions.setdefault(stage, []).append(version)
    for stage, numbers in versions.items():
        assert sorted(numbers) == list(range(1, max(numbers) + 1)), (
            f"{stage} prompt versions are not contiguous from 1"
        )


def test_registry_latest_matches_highest_pinned_version() -> None:
    registry = get_prompt_registry()
    pinned: dict[str, list[int]] = {}
    for path in _files(PINNED_DIR):
        stage, version = _asset_version(path)
        pinned.setdefault(stage, []).append(version)
        assert registry.get(stage, version) is not None
    for stage, versions in pinned.items():
        highest = max(versions)
        assert registry.latest(stage).version == highest
        assert registry.resolve([stage])[stage] == highest


def test_every_shipped_asset_is_serializable_to_itself() -> None:
    """Round-trip guard: registry assets must serialize back byte-stable.

    Guards against accidental formatting drift when prompts are re-rendered.
    """
    registry = get_prompt_registry()
    for path in _files(PINNED_DIR):
        stage, version = _asset_version(path)
        asset = registry.get(stage, version)
        rendered = {
            "name": asset.name,
            "version": asset.version,
            "system_prompt": asset.system_prompt,
            "user_prompt_template": asset.user_prompt_template,
            "temperature": asset.temperature,
            "max_tokens": asset.max_tokens,
            "json_schema_ref": asset.json_schema_ref,
        }
        pinned = json.loads(path.read_text())
        assert rendered == pinned, f"{path.name} re-renders differently"
