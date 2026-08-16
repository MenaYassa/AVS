"""Graph scalability smoke test (§6.5).

Exercises `assemble_canonical_session` against a large synthetic extraction
graph — hundreds of entities with thousands of relationships, including
duplicates, aliases, self-loops and dangling references — and asserts the
assembly stays correct at that scale: deterministic ids, no dangling edges,
no duplicate entities, and a schema-valid canonical session.

The engine's traversal for the *global* graph is the SQL `graph_traverse`
recursive CTE (`supabase/migrations/20260810000000_graph.sql`), which is not
hermetically unit-testable; this module smoke-tests the pure-Python side that
feeds it (per-session subgraph assembly) at volume.
"""

from __future__ import annotations

import random
import time
from typing import Any

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

# Number of entities / relationships to exercise. Large enough to surface
# quadratic behavior, small enough to stay a fast smoke (< 1s).
N_ENTITIES = 1_000
N_RELATIONSHIPS = 5_000


def _ctx() -> StageContext:
    ctx = StageContext(
        input_doc=InputDoc(
            kind="voice",
            text="raw",
            meta={"job_id": "scale-job", "language": "en"},
        ),
        prompt_versions={
            s: 1
            for s in (
                STAGE_CLEANUP,
                STAGE_CLASSIFICATION,
                STAGE_ENTITY_EXTRACTION,
                STAGE_KNOWLEDGE_EXTRACTION,
                STAGE_TAGS,
            )
        },
        budget=TOKENS,
    )
    ctx.intermediates[STAGE_CLEANUP] = {
        "cleaned_text": "Large session transcript.",
        "original_text": "raw",
    }
    ctx.intermediates[STAGE_CLASSIFICATION] = {
        "topics": [
            {
                "position": 0,
                "title": "Scale run",
                "description": "",
                "confidence": 0.9,
            }
        ]
    }
    ctx.intermediates[STAGE_KNOWLEDGE_EXTRACTION] = {
        "title": "Scale run",
        "alternative_titles": [],
        "summary": "Large graph smoke.",
        "summary_confidence": 0.8,
        "items": [
            {
                "type": "task",
                "title": "Run the smoke",
                "description": None,
                "priority": "high",
                "confidence": 0.9,
                "topic_position": 0,
            }
        ],
    }
    ctx.intermediates[STAGE_TAGS] = {"tags": []}
    return ctx


def _synthetic_graph(seed: int) -> tuple[list[dict], list[dict]]:
    """A deterministic large extraction graph with realistic noise."""
    rng = random.Random(seed)
    types = ("person", "project", "organization", "concept", "place", "date")
    names = [f"Entity {i}" for i in range(N_ENTITIES)]
    # Sprinkle alias collisions: 20% of entities are aliases of a prior one,
    # exercising identity-resolution merge at scale.
    entities: list[dict[str, Any]] = []
    for i, name in enumerate(names):
        entry: dict[str, Any] = {
            "name": name,
            "type": types[i % len(types)],
            "confidence": round(rng.uniform(0.5, 1.0), 3),
        }
        if rng.random() < 0.2 and i > 0:
            entry["aliases"] = [f"Alias of {i - 1}"]
        entities.append(entry)

    relationships: list[dict[str, Any]] = []
    rel_types = ("related_to", "participates_in", "depends_on", "leads")
    for _ in range(N_RELATIONSHIPS):
        source = rng.choice(names)
        target = rng.choice(names)
        rel: dict[str, Any] = {
            "source": source,
            "target": target,
            "type": rel_types[rng.randrange(len(rel_types))],
            "confidence": round(rng.uniform(0.5, 1.0), 3),
        }
        if rng.random() < 0.05:
            rel["source"] = f"Ghost-{rng.randrange(50)}"  # dangling
        if rng.random() < 0.05:
            rel["target"] = rel["source"]  # self-loop
        relationships.append(rel)
    return entities, relationships


def test_large_graph_assembles_correctly() -> None:
    entities, relationships = _synthetic_graph(seed=1)
    ctx = _ctx()
    ctx.intermediates[STAGE_ENTITY_EXTRACTION] = {
        "entities": entities,
        "relationships": relationships,
    }

    started = time.monotonic()
    session = assemble_canonical_session(ctx)
    elapsed = time.monotonic() - started

    built = session["session"]
    # Completes fast enough to stay a smoke test even on slow CI hosts.
    assert elapsed < 5.0, f"assembly too slow at scale: {elapsed:.2f}s"
    assert len(built["entities"]) > 0
    assert len(built["relationships"]) > 0

    # Schema-valid at scale (the canonical contract holds for large graphs).
    validate_session(session)

    entity_ids = {e["id"] for e in built["entities"]}
    names = {e["name"].casefold() for e in built["entities"]}
    assert len(names) == len(built["entities"]), "entity names must be unique"
    for edge in built["relationships"]:
        assert edge["source_id"] in entity_ids, "edges must never dangle"
        assert edge["target_id"] in entity_ids, "edges must never dangle"
        assert edge["source_id"] != edge["target_id"], "self-loops are dropped"


def test_large_graph_is_deterministic_across_runs() -> None:
    def build(seed: int) -> tuple[list[str], list[str]]:
        entities, relationships = _synthetic_graph(seed=seed)
        ctx = _ctx()
        ctx.intermediates[STAGE_ENTITY_EXTRACTION] = {
            "entities": entities,
            "relationships": relationships,
        }
        session = assemble_canonical_session(ctx)
        return (
            [e["id"] for e in session["session"]["entities"]],
            [r["id"] for r in session["session"]["relationships"]],
        )

    entity_ids_a, edge_ids_a = build(seed=1)
    entity_ids_b, edge_ids_b = build(seed=1)
    assert entity_ids_a == entity_ids_b
    assert edge_ids_a == edge_ids_b

    # A different job/session must still give per-session relationship ids
    # (cross-session edges never collide) — determinism by construction.
    ctx = _ctx()
    ctx.intermediates[STAGE_ENTITY_EXTRACTION] = {
        "entities": _synthetic_graph(seed=1)[0],
        "relationships": _synthetic_graph(seed=1)[1],
    }
    ctx.input_doc.meta["job_id"] = "different-job"
    other = assemble_canonical_session(ctx)
    other_edge_ids = [r["id"] for r in other["session"]["relationships"]]
    assert other_edge_ids != edge_ids_a
