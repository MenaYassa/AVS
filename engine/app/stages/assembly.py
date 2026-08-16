"""Canonical Session -> Topics -> Items assembly (§5.1).

Pure function over the stage intermediates: builds the canonical record with
deterministic ids, maps items to topics by `topic_position`, and aggregates
confidence. The validation stage runs this output through the shared JSON
Schema (`session.schema.json`) before it becomes the job result.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any

from app.stages.context import StageContext
from app.stages.names import (
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_ENTITY_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_TAGS,
)

_SESSION_NAMESPACE = uuid.UUID("3f0e4e88-3c9f-5d2e-9c1b-0a1b2c3d4e5f")
# Deterministic ids: the same entity name maps to the same node across sessions
# (identity resolution by construction, architecture §4.8), and a relationship
# maps to a distinct edge per session.
_ENTITY_NAMESPACE = uuid.UUID("4a1e5f99-4d0a-6e3f-bc2d-2b3c4d5e6f70")
_RELATIONSHIP_NAMESPACE = uuid.UUID("5b2f60aa-5e1b-7f40-cd3e-3c4d5e6f7081")


def _session_id(job_id: str | None) -> str:
    if job_id:
        return str(uuid.uuid5(_SESSION_NAMESPACE, job_id))
    return str(uuid.uuid4())


def _build_item(item: dict[str, Any], position: int, item_id: str) -> dict[str, Any]:
    built = {
        "id": item_id,
        "type": item["type"],
        "position": position,
        "title": item["title"],
        "priority": item.get("priority"),
        "confidence": item.get("confidence"),
    }
    description = item.get("description")
    if description:  # schema: description must be a string when present
        built["description"] = description
    return built


def _extraction_confidence(items: list[dict[str, Any]]) -> float | None:
    values = [i.get("confidence") for i in items if i.get("confidence") is not None]
    if not values:
        return None
    return round(sum(values) / len(values), 3)


def _build_tags(raw: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Normalizes the tags stage output for the canonical session: strips empty
    names, dedupes case-insensitively, and bounds the count."""
    seen: set[str] = set()
    tags: list[dict[str, Any]] = []
    for tag in raw:
        name = (tag.get("name") or "").strip()
        if not name or name.casefold() in seen:
            continue
        seen.add(name.casefold())
        entry: dict[str, Any] = {"name": name}
        if tag.get("confidence") is not None:
            entry["confidence"] = tag["confidence"]
        tags.append(entry)
        if len(tags) >= 20:
            break
    return tags


def _build_entities(
    raw: list[dict[str, Any]],
    relationships: list[dict[str, Any]],
    session_id: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Builds the canonical per-session subgraph (architecture §4.8).

    Entities get deterministic ids from their name, so the same real-world
    entity resolves to the same node across sessions. Identity resolution
    merges by name *and* by alias: an entity whose name matches a previously
    seen entity's alias collapses into it. Relationships reference entities by
    name and are dropped when their endpoints are missing from the final
    entity set (no dangling edges), then assigned per-session ids.
    """
    seen: dict[str, str] = {}
    id_by_name: dict[str, str] = {}
    alias_names: dict[str, str] = {}
    entities: list[dict[str, Any]] = []

    def resolve_id(name: str) -> str | None:
        key = name.casefold()
        return id_by_name.get(key) or alias_names.get(key)

    for entity in raw:
        name = (entity.get("name") or "").strip()
        if not name:
            continue
        existing = resolve_id(name)
        if existing is not None:
            continue
        entity_id = str(uuid.uuid5(_ENTITY_NAMESPACE, name))
        seen[name.casefold()] = name
        id_by_name[name.casefold()] = entity_id
        for alias in entity.get("aliases", []):
            alias = alias.strip()
            if alias:
                alias_names[alias.casefold()] = entity_id
        entry: dict[str, Any] = {
            "id": entity_id,
            "type": entity.get("type"),
            "name": name,
            "aliases": [a for a in entity.get("aliases", []) if a.strip()],
        }
        if entity.get("confidence") is not None:
            entry["confidence"] = entity["confidence"]
        entities.append(entry)

    built_edges: list[dict[str, Any]] = []
    seen_edges: set[str] = set()
    for rel in relationships:
        source = (rel.get("source") or "").strip()
        target = (rel.get("target") or "").strip()
        if not source or not target:
            continue
        source_id = resolve_id(source)
        target_id = resolve_id(target)
        if source_id is None or target_id is None or source_id == target_id:
            continue
        edge = {
            "source_id": source_id,
            "target_id": target_id,
            "type": rel.get("type"),
        }
        edge_key = (edge["source_id"], edge["target_id"], edge["type"])
        if edge_key in seen_edges:
            continue
        seen_edges.add(edge_key)
        edge["id"] = str(
            uuid.uuid5(
                _RELATIONSHIP_NAMESPACE,
                # Per-session ids: the same real-world edge appears in every
                # session's subgraph, but each gets its own row (the global
                # relationships table keys on id and carries session_id).
                "|".join((session_id, *edge_key)),
            )
        )
        if rel.get("confidence") is not None:
            edge["confidence"] = rel["confidence"]
        built_edges.append(edge)
    return entities, built_edges


def assemble_canonical_session(ctx: StageContext) -> dict[str, Any]:
    cleaning = ctx.require(STAGE_CLEANUP)
    knowledge = ctx.require(STAGE_KNOWLEDGE_EXTRACTION)
    classified = ctx.require(STAGE_CLASSIFICATION)["topics"]
    tagged = ctx.require(STAGE_TAGS)["tags"]
    extraction = ctx.require(STAGE_ENTITY_EXTRACTION)

    cleaned_text = cleaning["cleaned_text"]
    items_by_topic: dict[int, list[dict[str, Any]]] = {}
    orphaned: list[dict[str, Any]] = []
    for item in knowledge["items"]:
        topic_position = item.get("topic_position")
        if topic_position is None:
            orphaned.append(item)
        else:
            items_by_topic.setdefault(topic_position, []).append(item)

    topics: list[dict[str, Any]] = []
    item_counter = 0
    for topic in sorted(classified, key=lambda t: t["position"]):
        topic_items = []
        for item in items_by_topic.get(topic["position"], []):
            topic_items.append(
                _build_item(item, len(topic_items), f"item-{item_counter}")
            )
            item_counter += 1
        topic_record: dict[str, Any] = {
            "id": f"topic-{topic['position'] + 1}",
            "position": topic["position"],
            "title": topic["title"],
            "confidence": topic.get("confidence"),
            "items": topic_items,
        }
        if topic.get("description"):  # schema: string when present
            topic_record["description"] = topic["description"]
        topics.append(topic_record)

    if orphaned:
        topic_items = []
        for item in orphaned:
            topic_items.append(
                _build_item(item, len(topic_items), f"item-{item_counter}")
            )
            item_counter += 1
        topics.append(
            {
                "id": f"topic-{len(topics) + 1}",
                "position": len(topics),
                "title": "Other",
                "confidence": None,
                "items": topic_items,
            }
        )

    meta = ctx.input_doc.meta
    all_items = [
        item for topic in topics for item in topic["items"]
    ]
    session_id = _session_id(meta.get("job_id"))
    entities, relationships = _build_entities(
        extraction.get("entities", []),
        extraction.get("relationships", []),
        session_id,
    )
    return {
        "schema_version": 1,
        "session": {
            "id": session_id,
            "title": knowledge.get("title"),
            "alternative_titles": knowledge.get("alternative_titles", []),
            "summary": knowledge.get("summary"),
            "summary_confidence": knowledge.get("summary_confidence"),
            "extraction_confidence": _extraction_confidence(all_items),
            "language": meta.get("language"),
            "status": "ready",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "duration_sec": meta.get("duration_sec"),
            "word_count": len(cleaned_text.split()) if cleaned_text else None,
            "prompt_versions": dict(ctx.prompt_versions),
            "tags": _build_tags(tagged),
            "entities": entities,
            "relationships": relationships,
            "topics": topics,
        },
    }
