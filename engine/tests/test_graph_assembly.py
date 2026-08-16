"""Graph assembly tests (architecture §4.8): deterministic ids, alias merge,
no-dangling-edges, and per-session relationship ids."""

from __future__ import annotations

from app.inputs.base import InputDoc
from app.schemas import validate_session
from app.stages.assembly import assemble_canonical_session
from app.stages.context import StageContext, TokenBudget
from app.stages.names import (
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_ENTITY_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_TAGS,
)

TOKENS = TokenBudget(max_input_tokens=100_000, max_output_tokens=4096)


def _ctx(job_id: str = "job-1") -> StageContext:
    ctx = StageContext(
        input_doc=InputDoc(
            kind="voice",
            text="raw",
            meta={"job_id": job_id, "language": "en"},
        ),
        prompt_versions={s: 1 for s in (
            STAGE_CLEANUP,
            STAGE_CLASSIFICATION,
            STAGE_ENTITY_EXTRACTION,
            STAGE_KNOWLEDGE_EXTRACTION,
            STAGE_TAGS,
        )},
        budget=TOKENS,
    )
    ctx.intermediates[STAGE_CLEANUP] = {
        "cleaned_text": "We ship v2 by Friday with the Benchmark Platform.",
        "original_text": "raw",
    }
    ctx.intermediates[STAGE_CLASSIFICATION] = {
        "topics": [
            {
                "position": 0,
                "title": "Release plan",
                "description": "",
                "confidence": 0.9,
            }
        ]
    }
    ctx.intermediates[STAGE_KNOWLEDGE_EXTRACTION] = {
        "title": "Release plan",
        "alternative_titles": [],
        "summary": "Ship v2 by Friday.",
        "summary_confidence": 0.8,
        "items": [
            {
                "type": "task",
                "title": "Ship v2",
                "description": None,
                "priority": "high",
                "confidence": 0.9,
                "topic_position": 0,
            }
        ],
    }
    ctx.intermediates[STAGE_TAGS] = {"tags": []}
    ctx.intermediates[STAGE_ENTITY_EXTRACTION] = {
        "entities": [],
        "relationships": [],
    }
    return ctx


def _with_extraction(ctx: StageContext, *, entities: list, relationships: list) -> None:
    ctx.intermediates[STAGE_ENTITY_EXTRACTION] = {
        "entities": entities,
        "relationships": relationships,
    }


def test_entities_get_deterministic_ids_and_round_trip() -> None:
    ctx = _ctx()
    _with_extraction(
        ctx,
        entities=[
            {"name": "Benchmark Platform", "type": "project",
             "aliases": ["Benchmark"], "confidence": 0.95},
        ],
        relationships=[],
    )
    session = assemble_canonical_session(ctx)
    validate_session(session)

    entities = session["session"]["entities"]
    assert len(entities) == 1
    assert entities[0]["name"] == "Benchmark Platform"
    assert entities[0]["type"] == "project"
    assert entities[0]["aliases"] == ["Benchmark"]
    assert entities[0]["confidence"] == 0.95

    again = _ctx(job_id="job-2")
    _with_extraction(
        again,
        entities=[
            {"name": "Benchmark Platform", "type": "project",
             "aliases": [], "confidence": 0.9},
        ],
        relationships=[],
    )
    again = assemble_canonical_session(again)
    assert again["session"]["entities"][0]["id"] == entities[0]["id"], (
        "the same entity name must resolve to the same node across sessions"
    )


def test_alias_duplicates_merge_into_one_node() -> None:
    ctx = _ctx()
    _with_extraction(
        ctx,
        entities=[
            {"name": "Benchmark Platform", "type": "project",
             "aliases": ["Benchmark"], "confidence": 0.95},
            {"name": "Benchmark", "type": "project",
             "aliases": [], "confidence": 0.8},
        ],
        relationships=[],
    )
    session = assemble_canonical_session(ctx)
    assert len(session["session"]["entities"]) == 1
    assert session["session"]["entities"][0]["name"] == "Benchmark Platform"
    assert session["session"]["entities"][0]["aliases"] == ["Benchmark"]


def test_relationships_never_dangle() -> None:
    ctx = _ctx()
    _with_extraction(
        ctx,
        entities=[
            {"name": "Benchmark Platform", "type": "project",
             "aliases": [], "confidence": 0.9},
        ],
        relationships=[
            {"source": "Benchmark Platform", "target": "Acme",
             "type": "related_to", "confidence": 0.6},
            {"source": "Ghost", "target": "Benchmark Platform",
             "type": "related_to", "confidence": 0.6},
            {"source": "Benchmark Platform", "target": "Benchmark Platform",
             "type": "related_to", "confidence": 0.6},
        ],
    )
    session = assemble_canonical_session(ctx)
    validate_session(session)
    assert session["session"]["relationships"] == []


def test_relationships_dedupe_and_get_per_session_ids() -> None:
    def build(job_id: str) -> dict:
        ctx = _ctx(job_id=job_id)
        _with_extraction(
            ctx,
            entities=[
                {"name": "Benchmark Platform", "type": "project",
                 "aliases": [], "confidence": 0.9},
                {"name": "Friday", "type": "date",
                 "aliases": [], "confidence": 0.9},
            ],
            relationships=[
                {"source": "Friday", "target": "Benchmark Platform",
                 "type": "related_to", "confidence": 0.7},
                {"source": "Friday", "target": "Benchmark Platform",
                 "type": "related_to", "confidence": 0.8},
            ],
        )
        return assemble_canonical_session(ctx)

    session = build("job-a")
    edges = session["session"]["relationships"]
    assert len(edges) == 1
    assert edges[0]["confidence"] == 0.7  # first occurrence wins
    assert edges[0]["type"] == "related_to"

    other = build("job-b")
    assert len(other["session"]["relationships"]) == 1
    assert other["session"]["relationships"][0]["id"] != edges[0]["id"], (
        "relationship ids are per-session so cross-session edges never collide"
    )
