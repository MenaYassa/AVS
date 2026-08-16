"""Embedding provider interface for semantic search (architecture §5.2)."""

from __future__ import annotations

from typing import Protocol, runtime_checkable


@runtime_checkable
class EmbeddingProvider(Protocol):
    """Generates vector embeddings for text content."""

    def embed(self, text: str) -> list[float]: ...

    def embed_batch(self, texts: list[str]) -> list[list[float]]: ...

    @property
    def dimensions(self) -> int:
        """Embedding vector dimensions (e.g., 384 for all-MiniLM-L6-v2)."""
        ...


class SentenceTransformerEmbedding:
    """Sentence-transformers backed embedding provider."""

    def __init__(
        self, model_name: str = "sentence-transformers/all-MiniLM-L6-v2"
    ) -> None:
        self._model_name = model_name
        self._model = None

    @property
    def dimensions(self) -> int:
        return 384

    def embed(self, text: str) -> list[float]:
        result = self.embed_batch([text])
        return result[0]

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        if not texts:
            return []
        model = self._load_model()
        embeddings = model.encode(texts, convert_to_numpy=True)
        return [emb.tolist() for emb in embeddings]

    def _load_model(self):
        if self._model is None:
            from sentence_transformers import SentenceTransformer

            self._model = SentenceTransformer(self._model_name)
        return self._model


def get_embedding_provider() -> EmbeddingProvider:
    """Factory for the embedding provider."""
    return SentenceTransformerEmbedding()
