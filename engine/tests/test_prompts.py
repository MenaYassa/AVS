"""Prompt registry + immutable versioning tests (architecture §4.3)."""

from __future__ import annotations

import json

import pytest
from app.commands.chat_runner import CHAT_PROMPT_NAME
from app.commands.names import COMMAND_NAMES
from app.errors import InvalidRequestError
from app.prompts.registry import PromptRegistry, get_prompt_registry
from app.stages.names import PIPELINE_STAGES


def _write_asset(directory, name: str, version: int, **overrides) -> None:
    asset = {
        "name": name,
        "version": version,
        "system_prompt": "system",
        "user_prompt_template": "user {transcript}",
        "temperature": 0.2,
        "max_tokens": 1024,
        "json_schema_ref": f"stage.{name}",
    }
    asset.update(overrides)
    path = directory / f"{name}.{version}.json"
    path.write_text(json.dumps(asset))


def test_registry_loads_assets_for_every_stage_and_command() -> None:
    registry = get_prompt_registry()

    assert set(registry.stage_names) == (
        set(PIPELINE_STAGES) | set(COMMAND_NAMES) | {CHAT_PROMPT_NAME}
    )
    for stage in PIPELINE_STAGES:
        asset = registry.latest(stage)
        assert asset.name == stage
        assert asset.version == 1 or stage in (
            "entity_extraction",
            "task_extraction",
            "knowledge_extraction",
        )
        assert asset.system_prompt
        assert asset.json_schema_ref == f"stage.{stage}"
        # validation and embedding are deterministic (no LLM call)
        if stage not in ("validation", "embedding"):
            assert "{transcript}" in asset.user_prompt_template or stage in (
                "classification",
                "knowledge_extraction",
            )


def test_resolve_defaults_to_latest_for_pipeline() -> None:
    registry = get_prompt_registry()
    resolved = registry.resolve(list(PIPELINE_STAGES))

    memory_aware = ("entity_extraction", "task_extraction", "knowledge_extraction")
    assert resolved == {
        stage: (2 if stage in memory_aware else 1) for stage in PIPELINE_STAGES
    }


def test_resolve_honors_requested_existing_version(tmp_path) -> None:
    _write_asset(tmp_path, "cleanup", 1)
    _write_asset(tmp_path, "cleanup", 2, temperature=0.0)
    registry = PromptRegistry(tmp_path)

    resolved = registry.resolve(["cleanup"], requested={"cleanup": 1})
    assert resolved == {"cleanup": 1}
    assert registry.get("cleanup", 2).temperature == 0.0


def test_resolve_rejects_newer_than_shipped_version(tmp_path) -> None:
    _write_asset(tmp_path, "cleanup", 1)
    registry = PromptRegistry(tmp_path)

    with pytest.raises(InvalidRequestError) as exc:
        registry.resolve(["cleanup"], requested={"cleanup": 3})
    assert exc.value.code == "INVALID_REQUEST"
    assert exc.value.details == {
        "name": "cleanup",
        "version": 3,
        "latest": 1,
    }


def test_resolve_rejects_unknown_stage(tmp_path) -> None:
    _write_asset(tmp_path, "cleanup", 1)
    registry = PromptRegistry(tmp_path)

    with pytest.raises(InvalidRequestError) as exc:
        registry.resolve(["cleanup"], requested={"ghost": 1})
    assert exc.value.code == "INVALID_REQUEST"
    assert "ghost" in str(exc.value.message)


def test_registry_rejects_misnamed_asset(tmp_path) -> None:
    (tmp_path / "oops.json").write_text("{}")
    with pytest.raises(InvalidRequestError) as exc:
        PromptRegistry(tmp_path)
    assert exc.value.code == "INVALID_REQUEST"


def test_assets_are_immutable() -> None:
    asset = get_prompt_registry().latest("cleanup")
    with pytest.raises(ValueError):
        asset.version = 99
