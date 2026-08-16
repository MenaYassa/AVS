"""Canonical JSON Schema tests (architecture §5.2, §10.1 'Schema validation is
the backbone')."""

from __future__ import annotations

import pytest
from app.schemas import validate_job, validate_session


def _valid_session() -> dict:
    return {
        "schema_version": 1,
        "session": {
            "id": "s1",
            "title": "EAG Benchmark Platform Planning",
            "alternative_titles": ["Benchmark Planning"],
            "summary": "one-paragraph overview",
            "summary_confidence": 0.9,
            "extraction_confidence": 0.87,
            "language": "en",
            "status": "ready",
            "created_at": "2026-01-01T00:00:00Z",
            "duration_sec": 240,
            "word_count": 612,
            "prompt_versions": {"cleanup": 9, "knowledge_extraction": 5},
            "topics": [
                {
                    "id": "t1",
                    "position": 0,
                    "title": "Benchmark Platform",
                    "description": "...",
                    "confidence": 0.92,
                    "items": [
                        {
                            "id": "i1",
                            "type": "task",
                            "position": 0,
                            "title": "Add caching to benchmark platform",
                            "description": "...",
                            "priority": "high",
                            "timestamp_sec": 12.5,
                            "confidence": 0.95,
                        }
                    ],
                }
            ],
        },
    }


def test_valid_canonical_session_passes() -> None:
    validate_session(_valid_session())


def test_invalid_item_type_fails() -> None:
    session = _valid_session()
    session["session"]["topics"][0]["items"][0]["type"] = "mystery"
    with pytest.raises(Exception):
        validate_session(session)


def test_wrong_schema_version_fails() -> None:
    session = _valid_session()
    session["schema_version"] = 2
    with pytest.raises(Exception):
        validate_session(session)


def test_unknown_top_level_key_fails() -> None:
    session = _valid_session()
    session["session"]["hacked"] = True
    with pytest.raises(Exception):
        validate_session(session)


def test_org_flags_and_tags_validate() -> None:
    session = _valid_session()
    session["session"]["favorite"] = True
    session["session"]["archived"] = True
    session["session"]["deleted"] = False
    session["session"]["pinned"] = True
    session["session"]["tags"] = [
        {"name": "release planning", "confidence": 0.9},
        {"name": "shipping"},
    ]
    validate_session(session)


def _with_graph(session: dict) -> dict:
    session["session"]["entities"] = [
        {
            "id": "e-benchmark",
            "type": "project",
            "name": "Benchmark Platform",
            "aliases": ["Benchmark"],
            "confidence": 0.95,
        },
        {
            "id": "e-friday",
            "type": "date",
            "name": "Friday",
            "confidence": 0.9,
        },
    ]
    session["session"]["relationships"] = [
        {
            "id": "r1",
            "source_id": "e-friday",
            "target_id": "e-benchmark",
            "type": "related_to",
            "confidence": 0.7,
        }
    ]
    return session


def test_entities_and_relationships_validate() -> None:
    validate_session(_with_graph(_valid_session()))


def test_entity_requires_type_from_enum() -> None:
    session = _with_graph(_valid_session())
    session["session"]["entities"][0]["type"] = "mystery"
    with pytest.raises(Exception):
        validate_session(session)


def test_entity_requires_name() -> None:
    session = _with_graph(_valid_session())
    session["session"]["entities"][0]["name"] = ""
    with pytest.raises(Exception):
        validate_session(session)


def test_relationship_requires_valid_endpoints_and_type() -> None:
    session = _with_graph(_valid_session())
    session["session"]["relationships"][0]["source_id"] = ""
    with pytest.raises(Exception):
        validate_session(session)

    session = _with_graph(_valid_session())
    session["session"]["relationships"][0]["type"] = "unknown"
    with pytest.raises(Exception):
        validate_session(session)


def test_tag_requires_name() -> None:
    session = _valid_session()
    session["session"]["tags"] = [{"confidence": 0.9}]
    with pytest.raises(Exception):
        validate_session(session)


def test_confidence_bounds_are_enforced() -> None:
    session = _valid_session()
    session["session"]["summary_confidence"] = 1.4
    with pytest.raises(Exception):
        validate_session(session)


def test_valid_job_passes() -> None:
    validate_job(
        {
            "id": "j1",
            "user_id": "u1",
            "kind": "analyze",
            "status": "queued",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
        }
    )


def test_invalid_job_status_fails() -> None:
    with pytest.raises(Exception):
        validate_job(
            {
                "id": "j1",
                "user_id": "u1",
                "kind": "analyze",
                "status": "warped",
                "created_at": "2026-01-01T00:00:00Z",
                "updated_at": "2026-01-01T00:00:00Z",
            }
        )
