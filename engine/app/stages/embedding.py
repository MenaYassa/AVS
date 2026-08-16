"""Embedding stage: generates vector embeddings for semantic search (§6.1)."""

from __future__ import annotations

from app.providers.embedding import get_embedding_provider
from app.stages.base import DeterministicStage
from app.stages.context import StageContext
from app.stages.names import STAGE_EMBEDDING


class EmbeddingStage(DeterministicStage):
    """Generates embeddings for session content (title, topics, items).

    Runs after validation to ensure we have canonical data.
    """

    name = STAGE_EMBEDDING

    def __init__(self) -> None:
        self._provider = get_embedding_provider()

    def build(self, ctx: StageContext) -> dict[str, object]:
        session = ctx.intermediates.get("validation", {})
        if not session:
            return {"embedding": [], "dimension": 0}

        text_parts = []

        if title := session.get("title"):
            text_parts.append(title)
        if summary := session.get("summary"):
            text_parts.append(summary)
        if topics := session.get("topics", []):
            for topic in topics:
                if topic_name := topic.get("title"):
                    text_parts.append(topic_name)
                if items := topic.get("items", []):
                    for item in items:
                        if content := item.get("content"):
                            text_parts.append(content)

        full_text = " | ".join(text_parts)
        embedding = self._provider.embed(full_text)

        return {
            "embedding": embedding,
            "dimension": self._provider.dimensions,
            "text_length": len(full_text),
        }


def get_embedding_stage() -> EmbeddingStage:
    return EmbeddingStage()
