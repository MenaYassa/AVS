"""Vector store seam for semantic search (architecture §5.4, §6.1).

Searches session embeddings by cosine similarity. The engine never talks to
embedding providers for search: queries are embedded with the same
`EmbeddingProvider` used by the pipeline, then handed to the configured store.

- `NullVectorStore` is the default (hermetic, no database configured).
- `PgsqlVectorStore` queries Supabase Postgres via pgvector (asyncpg).

The store is resolved through `get_vector_store()`, which tests can monkeypatch.
"""

from __future__ import annotations

import logging
from typing import Any, Protocol

from app.config import settings

logger = logging.getLogger(__name__)


class VectorStore(Protocol):
    """Finds sessions nearest to a query embedding by cosine similarity."""

    async def search(
        self,
        query_embedding: list[float],
        *,
        user_id: str,
        limit: int,
        threshold: float,
    ) -> list[dict[str, Any]]:
        """Return rows with `session_id`, `title`, `summary`, `similarity`."""
        ...


class NullVectorStore:
    """No pgvector backend configured — returns no results."""

    async def search(
        self,
        query_embedding: list[float],
        *,
        user_id: str,
        limit: int,
        threshold: float,
    ) -> list[dict[str, Any]]:
        return []


class PgsqlVectorStore:
    """pgvector-backed search over Supabase Postgres (asyncpg, §5.4).

    Sessions carry an `embedding vector(384)` column (HNSW cosine index, see
    `supabase/migrations/20260811000000_embedding.sql`). Cosine distance `<=>`
    is converted to similarity `1 - distance`; rows below [threshold] are
    excluded.
    """

    def __init__(self, dsn: str) -> None:
        import asyncpg

        self._dsn = dsn
        self._asyncpg = asyncpg
        self._pool: Any | None = None

    async def _connection(self) -> Any:
        if self._pool is None:
            self._pool = await self._asyncpg.create_pool(self._dsn, min_size=1)
        return self._pool

    async def search(
        self,
        query_embedding: list[float],
        *,
        user_id: str,
        limit: int,
        threshold: float,
    ) -> list[dict[str, Any]]:
        if not query_embedding:
            return []
        pool = await self._connection()
        sql = """
            SELECT s.id AS session_id, s.title AS title, s.summary AS summary,
                   1 - (s.embedding <=> $1::vector) AS similarity
            FROM sessions s
            WHERE s.embedding IS NOT NULL
              AND s.user_id = $2
              AND s.deleted = false
              AND 1 - (s.embedding <=> $1::vector) >= $3
            ORDER BY s.embedding <=> $1::vector
            LIMIT $4
        """
        rows = await pool.fetch(sql, query_embedding, user_id, threshold, limit)
        return [
            {
                "session_id": row["session_id"],
                "title": row["title"],
                "summary": row["summary"],
                "similarity": float(row["similarity"]),
            }
            for row in rows
        ]


def get_vector_store() -> VectorStore:
    """Resolve the configured vector store (null by default)."""
    if settings.database_url:
        return PgsqlVectorStore(settings.database_url)
    return NullVectorStore()
