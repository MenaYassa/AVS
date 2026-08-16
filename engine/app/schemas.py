"""Canonical JSON Schema loading + validation (architecture §5.2).

`engine/schemas/*.json` is the single source of truth. Both the engine and the
vendored Dart copy validate against these files.
"""

from __future__ import annotations

import json
import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import jsonschema

_SCHEMA_DIR_ENV = "ENGINE_SCHEMA_DIR"


def _schema_dir() -> Path:
    if env := os.environ.get(_SCHEMA_DIR_ENV):
        return Path(env)
    # Source layout: engine/app/schemas.py -> engine/schemas.
    return Path(__file__).resolve().parent.parent / "schemas"


SCHEMA_DIR = _schema_dir()


@lru_cache
def load_schema(name: str) -> dict[str, Any]:
    path = SCHEMA_DIR / f"{name}.schema.json"
    with path.open() as handle:
        return json.load(handle)


def job_schema() -> dict[str, Any]:
    return load_schema("job")


def session_schema() -> dict[str, Any]:
    return load_schema("session")


def draft_schema() -> dict[str, Any]:
    return load_schema("draft")


def chat_schema() -> dict[str, Any]:
    return load_schema("chat")


def insights_schema() -> dict[str, Any]:
    return load_schema("insights")


def plugin_schema() -> dict[str, Any]:
    return load_schema("plugin")


def validate_against_schema(
    instance: Any,
    schema: dict[str, Any],
    *,
    allow_extra: bool = False,
) -> None:
    """Validate `instance` against `schema`; raise ValueError on failure.

    `allow_extra=True` permits properties not listed in the schema (used for
    partial request bodies that are not yet complete canonical records).
    """
    if allow_extra:
        schema = {**schema, "additionalProperties": True}
    jsonschema.validate(instance=instance, schema=schema)


def validate_session(instance: Any) -> None:
    validate_against_schema(instance, session_schema())


def validate_job(instance: Any) -> None:
    validate_against_schema(instance, job_schema())
