"""Prompt registry + versioned assets (architecture §4.3).

Assets live at `engine/prompts/<stage>.<version>.json` and are immutable:
a version is never edited in place — new behavior ships as a higher version.
The orchestrator records the resolved `prompt_versions` on every session, so
any output is reproducible from its prompt set.

The registry validates that requested versions exist and are not newer than
the latest shipped version (immutability guard). Unknown names or too-new
versions raise a structured `InvalidRequestError`.
"""

from __future__ import annotations

import os
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.errors import InvalidRequestError

_PROMPT_DIR_ENV = "ENGINE_PROMPT_DIR"


class PromptAsset(BaseModel):
    """One immutable versioned prompt asset (§4.3)."""

    model_config = ConfigDict(frozen=True)

    name: str
    version: int = Field(ge=1)
    system_prompt: str
    user_prompt_template: str
    temperature: float | None = None
    max_tokens: int | None = Field(default=None, ge=1)
    json_schema_ref: str | None = None


def default_prompt_dir() -> Path:
    if env := os.environ.get(_PROMPT_DIR_ENV):
        return Path(env)
    # Source layout: engine/app/prompts/registry.py -> engine/prompts.
    return Path(__file__).resolve().parent.parent.parent / "prompts"


class PromptRegistry:
    """Loads all assets once and resolves immutable versions for a pipeline."""

    _ASSET_NAME = re.compile(r"^(?P<name>[a-z0-9_]+)\.(?P<version>\d+)\.json$")

    def __init__(self, directory: Path | None = None) -> None:
        self.directory = directory or default_prompt_dir()
        self._by_name: dict[str, dict[int, PromptAsset]] = {}
        self._load()

    def _load(self) -> None:
        if not self.directory.is_dir():
            raise InvalidRequestError(
                f"Prompt directory not found: {self.directory}",
                details={"path": str(self.directory)},
            )
        for path in sorted(self.directory.glob("*.json")):
            match = self._ASSET_NAME.match(path.name)
            if match is None:
                raise InvalidRequestError(
                    f"Prompt asset must be named <stage>.<version>.json: {path.name}",
                    details={"path": path.name},
                )
            asset = PromptAsset.model_validate_json(path.read_text())
            if asset.name != match.group("name"):
                raise InvalidRequestError(
                    f"Asset name mismatch in {path.name}",
                    details={"file": match.group("name"), "asset": asset.name},
                )
            if int(match.group("version")) != asset.version:
                raise InvalidRequestError(
                    f"Asset version mismatch in {path.name}",
                    details={"file": match.group("version"), "asset": asset.version},
                )
            self._by_name.setdefault(asset.name, {})[asset.version] = asset

    @property
    def stage_names(self) -> list[str]:
        return sorted(self._by_name)

    def latest(self, name: str) -> PromptAsset:
        versions = self._by_name.get(name)
        if not versions:
            raise InvalidRequestError(
                f"Unknown prompt stage: {name!r}",
                details={"known": self.stage_names},
            )
        return versions[max(versions)]

    def get(self, name: str, version: int) -> PromptAsset:
        asset = self._by_name.get(name, {}).get(version)
        if asset is None:
            known = self._by_name.get(name)
            latest = max(known) if known else None
            raise InvalidRequestError(
                f"Unknown prompt version {name}.{version}",
                details={"name": name, "version": version, "latest": latest},
            )
        return asset

    def resolve(
        self, stage_names: list[str], requested: dict[str, Any] | None = None
    ) -> dict[str, int]:
        """Return `{stage_name: version}` for a pipeline, immutable-version-safe.

        Requested versions are honored only if they already exist (a requested
        version newer than the latest shipped is rejected rather than silently
        downgraded), and unknown stage names are rejected.
        """
        requested = requested or {}
        for name, version in requested.items():
            self.get(name, int(version))  # validates existence + immutability
        resolved: dict[str, int] = {}
        for name in stage_names:
            requested_version = requested.get(name)
            resolved[name] = (
                requested_version
                if requested_version is not None
                else self.latest(name).version
            )
        return resolved


@lru_cache
def get_prompt_registry() -> PromptRegistry:
    return PromptRegistry()
