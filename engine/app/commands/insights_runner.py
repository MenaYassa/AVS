"""Cross-session intelligence runner (architecture §4.9, spec §19).

An insights job (`JobKind.insights`) carries compact descriptors of the user's
sessions in `options.sessions`; the runner clusters entity/tag labels across
those sessions and returns explainable statements like *"You've discussed
Benchmark Platform in 12 sessions"*, each recording its source sessions so
every claim is traceable.

The clustering is deterministic math over the shared-entity/tag graph — no LLM
call, no prompt asset — so insights are fully reproducible and cheap. Vector
similarity (embeddings) is a Phase 6 concern (architecture §4.9, roadmap §6.1);
this runner's similarity axis is exact label overlap, which needs no provider.

Privacy (architecture §4.9, §12): the engine derives nothing itself — the
client ships only the compact descriptors it chooses to share, and the result
is computed strictly within that request. There is no cross-user data, ever.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from app.errors import JobFailedError
from app.models import Job
from app.schemas import insights_schema, validate_against_schema
from app.stages.base import StageOutputError

# Labels appearing in fewer distinct sessions than this are not insights.
_DEFAULT_MIN_SESSIONS = 2
# Hard cap on returned insights (ranked by evidence strength).
_DEFAULT_MAX_INSIGHTS = 20
# Cap on the transcript slice searched for a snippet.
_MAX_TRANSCRIPT_CHARS = 20_000
# Snippet window around a matched label.
_SNIPPET_PAD_BEFORE = 40
_SNIPPET_PAD_AFTER = 80
_SNIPPET_MAX = 160

_WORD_RE = re.compile(r"\w+", re.UNICODE)


class InsightSource(BaseModel):
    model_config = ConfigDict(extra="forbid")

    session_id: str = Field(min_length=1)
    title: str = Field(min_length=1)
    snippet: str | None = None


class Insight(BaseModel):
    model_config = ConfigDict(extra="forbid")

    kind: str
    label: str = Field(min_length=1)
    session_count: int = Field(ge=1)
    mention_count: int = Field(default=0, ge=0)
    confidence: float = Field(ge=0.0, le=1.0)
    statement: str = Field(min_length=1)
    sources: list[InsightSource] = Field(default_factory=list)


def _require_sessions(options: dict[str, Any]) -> list[dict[str, Any]]:
    sessions = options.get("sessions")
    if not isinstance(sessions, list) or not sessions:
        raise JobFailedError(
            "An insights job needs options.sessions with at least one session",
            code="INSIGHTS_CONTEXT_INVALID",
            details={"got": type(sessions).__name__ if sessions is not None else None},
        )
    for session in sessions:
        if not isinstance(session, dict) or not session.get("session_id"):
            raise JobFailedError(
                "Each session descriptor needs a non-empty session_id",
                code="INSIGHTS_CONTEXT_INVALID",
            )
    return sessions


def _label_key(kind: str, label: str) -> tuple[str, str]:
    return kind, label.strip().casefold()


def _clean_label(label: Any) -> str | None:
    if isinstance(label, dict):
        label = label.get("name") or label.get("title") or label.get("label")
    if not isinstance(label, str):
        return None
    text = label.strip()
    if not text or len(text) > 200:
        return None
    return text


def _determine_kind(default_kind: str, raw: Any) -> str:
    if isinstance(raw, dict):
        raw_type = str(raw.get("type") or "").strip().lower()
        if raw_type in ("person", "project", "task", "decision"):
            return raw_type
    return default_kind


def _text_window(text: str, needle: str) -> str | None:
    """A short excerpt of `text` around the first case-insensitive `needle`."""
    idx = text.casefold().find(needle.casefold())
    if idx < 0:
        return None
    start = max(0, idx - _SNIPPET_PAD_BEFORE)
    end = min(len(text), idx + len(needle) + _SNIPPET_PAD_AFTER)
    snippet = " ".join(text[start:end].split())
    if len(snippet) > _SNIPPET_MAX:
        snippet = snippet[:_SNIPPET_MAX].rstrip() + "…"
    return snippet


def _find_snippet(label: str, session: dict[str, Any]) -> str | None:
    """First mention of `label` in the session's items/summary/transcript."""
    for item in session.get("items") or []:
        if isinstance(item, dict):
            for key in ("title", "description"):
                value = item.get(key)
                if isinstance(value, str) and value:
                    snippet = _text_window(value, label)
                    if snippet:
                        return snippet
    summary = session.get("summary")
    if isinstance(summary, str) and summary:
        snippet = _text_window(summary, label)
        if snippet:
            return snippet
    transcript = session.get("transcript")
    if isinstance(transcript, str) and transcript:
        snippet = _text_window(transcript[:_MAX_TRANSCRIPT_CHARS], label)
        if snippet:
            return snippet
    return None


def _statement(kind: str, label: str, count: int) -> str:
    plural = "s" if count != 1 else ""
    if kind == "tag":
        return f"You've used the tag '{label}' in {count} session{plural}."
    if kind == "person":
        return f"You've mentioned or met with {label} in {count} session{plural}."
    if kind == "project":
        return f"Project '{label}' appears across {count} session{plural}."
    if kind == "task":
        return f"Task '{label}' recurs across {count} session{plural}."
    if kind == "decision":
        return f"Decision regarding '{label}' recurs in {count} session{plural}."
    return f"You've discussed {label} in {count} session{plural}."


def _build_insights(
    sessions: list[dict[str, Any]],
    min_sessions: int,
    max_insights: int,
) -> list[dict[str, Any]]:
    """Cluster labels across sessions and rank the resulting insights.

    Graph clustering: labels are shared nodes; an edge exists between a session
    and every label it mentions. A label becomes an insight when it is
    connected to at least `min_sessions` distinct sessions.
    """
    # label_key -> (display label, {session_id: session})
    clusters: dict[tuple[str, str], dict[str, Any]] = {}
    for session in sessions:
        session_id = session["session_id"]
        title = (
            str(session.get("title") or "").strip() or f"Untitled session {session_id}"
        )

        # 1. Entities (with type support for person/project)
        for raw in session.get("entities") or []:
            label = _clean_label(raw)
            if label is None:
                continue
            kind = _determine_kind("entity", raw)
            key = _label_key(kind, label)
            cluster = clusters.setdefault(key, {"label": label, "sessions": {}})
            cluster["sessions"][session_id] = {
                "session_id": session_id,
                "title": title,
                "raw": session,
            }

        # 2. Tags
        for raw in session.get("tags") or []:
            label = _clean_label(raw)
            if label is None:
                continue
            key = _label_key("tag", label)
            cluster = clusters.setdefault(key, {"label": label, "sessions": {}})
            cluster["sessions"][session_id] = {
                "session_id": session_id,
                "title": title,
                "raw": session,
            }

        # 3. Items (pattern detection for recurring tasks & decisions)
        for raw in session.get("items") or []:
            if isinstance(raw, dict):
                item_type = str(raw.get("type") or "").strip().lower()
                if item_type in ("task", "decision"):
                    label = _clean_label(raw)
                    if label is None:
                        continue
                    key = _label_key(item_type, label)
                    cluster = clusters.setdefault(key, {"label": label, "sessions": {}})
                    cluster["sessions"][session_id] = {
                        "session_id": session_id,
                        "title": title,
                        "raw": session,
                    }

    insights: list[dict[str, Any]] = []
    for (kind, _), cluster in clusters.items():
        sources = sorted(
            cluster["sessions"].values(), key=lambda s: s["title"].casefold()
        )
        if len(sources) < min_sessions:
            continue
        count = len(sources)
        confidence = round(min(0.95, 0.5 + (count - _DEFAULT_MIN_SESSIONS) * 0.15), 2)
        insights.append(
            {
                "kind": kind,
                "label": cluster["label"],
                "session_count": count,
                "mention_count": count,
                "confidence": confidence,
                "statement": _statement(kind, cluster["label"], count),
                "sources": [
                    {
                        "session_id": source["session_id"],
                        "title": source["title"],
                        "snippet": _find_snippet(cluster["label"], source["raw"]),
                    }
                    for source in sources
                ],
            }
        )

    insights.sort(key=lambda i: (-i["session_count"], i["label"].casefold()))
    return insights[:max_insights]


def run_insights(job: Job) -> dict[str, Any]:
    """Execute an insights job; returns the validated InsightResult.

    Pure and synchronous: no provider, no prompt asset, no I/O beyond the
    request body the client shipped in `options.sessions`.
    """
    options = job.options or {}
    sessions = _require_sessions(options)
    min_sessions = int(options.get("min_sessions") or _DEFAULT_MIN_SESSIONS)
    max_insights = int(options.get("max_insights") or _DEFAULT_MAX_INSIGHTS)
    if min_sessions < 1:
        raise JobFailedError(
            "options.min_sessions must be >= 1",
            code="INSIGHTS_CONTEXT_INVALID",
        )
    if max_insights < 1:
        raise JobFailedError(
            "options.max_insights must be >= 1",
            code="INSIGHTS_CONTEXT_INVALID",
        )

    result: dict[str, Any] = {
        "insights": _build_insights(sessions, min_sessions, max_insights),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "total_sessions": len(sessions),
    }
    try:
        validate_against_schema(result, insights_schema())
    except Exception as exc:  # noqa: BLE001
        raise StageOutputError(f"insights: {exc}") from exc
    return result
