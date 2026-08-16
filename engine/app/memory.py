"""AI memory context (architecture §4.9, spec §19).

Memory is an **opt-in**, token-budgeted block of related-session context the
client ships alongside an `analyze` or `chat` job (`options.memory`). Each
descriptor is a compact digest of another session (title, summary, open tasks)
and is tagged with its source `session_id` so every downstream claim is
traceable. The engine only ever sees what the client ships — nothing is stored
server-side and no cross-user data exists here.

`normalize_memory` validates and bounds the descriptors; `render_memory_block`
turns them into the prompt-shaped, source-tagged block the versioned prompt
assets insert (empty when there is no memory, so old prompt versions and
memory-less runs behave identically).
"""

from __future__ import annotations

from typing import Any

from app.errors import JobFailedError

_MAX_MEMORY_ENTRIES = 8
_MAX_TITLE_CHARS = 200
_MAX_SUMMARY_CHARS = 400
_MAX_TASKS_PER_SESSION = 6
_MAX_TASK_CHARS = 200
_MAX_TOTAL_CHARS = 6_000


def normalize_memory(raw: Any) -> list[dict[str, Any]]:
    """Validate and bound `options.memory` into clean memory descriptors.

    Raises `JobFailedError(code="MEMORY_CONTEXT_INVALID")` when the shape is
    wrong; returns `[]` when memory is absent (opt-out).
    """
    if raw is None:
        return []
    if not isinstance(raw, list):
        raise JobFailedError(
            "Memory context must be a list of session descriptors",
            code="MEMORY_CONTEXT_INVALID",
            details={"got": type(raw).__name__},
        )

    items: list[dict[str, Any]] = []
    for entry in raw[:_MAX_MEMORY_ENTRIES]:
        if not isinstance(entry, dict):
            raise JobFailedError(
                "Memory descriptors must be objects",
                code="MEMORY_CONTEXT_INVALID",
                details={"index": len(items)},
            )
        session_id = entry.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            raise JobFailedError(
                "Memory descriptors need a non-empty session_id",
                code="MEMORY_CONTEXT_INVALID",
                details={"index": len(items)},
            )
        title = entry.get("title")
        summary = entry.get("summary")
        open_tasks = entry.get("open_tasks")
        has_text = any(isinstance(v, str) and v.strip() for v in (title, summary))
        has_tasks = isinstance(open_tasks, list)
        if not has_text and not has_tasks:
            raise JobFailedError(
                "Memory descriptors need a title, summary, or open_tasks",
                code="MEMORY_CONTEXT_INVALID",
                details={"session_id": session_id},
            )

        tasks = []
        if has_tasks:
            for task in open_tasks[:_MAX_TASKS_PER_SESSION]:
                if isinstance(task, str) and task.strip():
                    tasks.append(task.strip()[:_MAX_TASK_CHARS])
        items.append(
            {
                "session_id": session_id,
                "title": title.strip()[:_MAX_TITLE_CHARS]
                if isinstance(title, str)
                else "",
                "summary": summary.strip()[:_MAX_SUMMARY_CHARS]
                if isinstance(summary, str)
                else "",
                "open_tasks": tasks,
            }
        )
    return items


def render_memory_block(memory: list[dict[str, Any]]) -> str:
    """Render the source-tagged memory block for a prompt template.

    Returns `""` when there is nothing to inject (memory-less run or the
    feature is off), which keeps old prompt versions and plain runs identical.
    """
    if not memory:
        return ""

    lines: list[str] = []
    total = 0
    for entry in memory:
        title = entry.get("title") or "(untitled session)"
        header = f"[source: {entry['session_id']}] {title}"
        block = [header]
        if entry.get("summary"):
            block.append(f"Summary: {entry['summary']}")
        open_tasks = entry.get("open_tasks") or []
        if open_tasks:
            block.append("Open tasks: " + "; ".join(open_tasks))
        block.append("")
        size = sum(len(line) for line in block)
        if total + size > _MAX_TOTAL_CHARS:
            break
        total += size
        lines.extend(block)

    return "\n".join(lines).rstrip()
