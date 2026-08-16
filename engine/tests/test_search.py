"""Semantic search API tests (architecture §5.4, §6.1).

The endpoint embeds the query and returns the query embedding alongside results
from the configured vector store. Hermetic: the embedding provider and vector
store are monkeypatched, so no model weights or database are touched.
"""

from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock

import pytest
from app.main import app
from app.routers import search as search_module
from fastapi.testclient import TestClient

client = TestClient(app)

DIMS = 384
QUERY_EMBEDDING = [0.01 * i for i in range(1, DIMS + 1)]


class _FakeProvider:
    dimensions = DIMS

    def embed(self, text: str) -> list[float]:
        return QUERY_EMBEDDING

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [QUERY_EMBEDDING for _ in texts]


class _FakeStore:
    def __init__(self, rows: list[dict]) -> None:
        self._rows = rows
        self.searches: list[dict] = []

    async def search(
        self,
        query_embedding: list[float],
        *,
        user_id: str,
        limit: int,
        threshold: float,
    ) -> list[dict]:
        self.searches.append(
            {
                "query_embedding": query_embedding,
                "user_id": user_id,
                "limit": limit,
                "threshold": threshold,
            }
        )
        return self._rows


@pytest.fixture
def store() -> _FakeStore:
    return _FakeStore([])


@pytest.fixture(autouse=True)
def _hermetic_dependencies(monkeypatch: pytest.MonkeyPatch, store: _FakeStore) -> None:
    monkeypatch.setattr(search_module, "get_embedding_provider", _FakeProvider)
    monkeypatch.setattr(search_module, "get_vector_store", lambda: store)


def test_semantic_search_returns_query_embedding_with_no_results(
    store: _FakeStore,
) -> None:
    store._rows = []
    response = client.post(
        "/api/v1/search/semantic",
        headers={"X-User-Id": "u1"},
        json={"query": "release planning", "limit": 5},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["results"] == []
    assert data["total"] == 0
    assert data["dimension"] == DIMS
    assert data["query_embedding"] == QUERY_EMBEDDING


def test_semantic_search_returns_store_results(store: _FakeStore) -> None:
    store._rows = [
        {
            "session_id": "s1",
            "title": "Release plan",
            "summary": "Ship the platform.",
            "similarity": 0.91,
        }
    ]
    response = client.post(
        "/api/v1/search/semantic",
        headers={"X-User-Id": "u1"},
        json={"query": "release planning"},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["total"] == 1
    assert data["results"][0]["session_id"] == "s1"
    assert data["results"][0]["similarity"] == 0.91


def test_semantic_search_passes_query_and_user_to_store(store: _FakeStore) -> None:
    client.post(
        "/api/v1/search/semantic",
        headers={"X-User-Id": "u42"},
        json={"query": "benchmark", "limit": 7, "threshold": 0.5},
    )

    assert store.searches == [
        {
            "query_embedding": QUERY_EMBEDDING,
            "user_id": "u42",
            "limit": 7,
            "threshold": 0.5,
        }
    ]


def test_semantic_search_requires_auth() -> None:
    response = client.post("/api/v1/search/semantic", json={"query": "hello"})
    assert response.status_code == 401


def test_pgsql_vector_store_builds_pgvector_query() -> None:
    """The asyncpg query is exercised against a fake pool/connection.

    Verifies the SQL selects cosine-similarity rows scoped to the user and
    threshold, without a live database.
    """
    from app.vector_store import PgsqlVectorStore

    store = PgsqlVectorStore("postgresql://user:pass@host/db")

    fetch = AsyncMock(
        return_value=[
            {
                "session_id": "s1",
                "title": "Release plan",
                "summary": None,
                "similarity": 0.88,
            }
        ]
    )
    fake_pool = AsyncMock()
    fake_pool.fetch = fetch
    store._pool = fake_pool

    rows = asyncio.run(
        store.search(
            QUERY_EMBEDDING,
            user_id="u1",
            limit=3,
            threshold=0.6,
        )
    )

    assert fetch.await_count == 1
    assert rows[0]["session_id"] == "s1"
    assert rows[0]["similarity"] == 0.88
    call = fetch.await_args
    sql, args = call.args[0], call.args[1:]
    assert "embedding <=> $1::vector" in sql
    assert "s.user_id = $2" in sql
    assert args == (QUERY_EMBEDDING, "u1", 0.6, 3)


def test_pgsql_vector_store_empty_embedding_skips_query() -> None:
    from app.vector_store import PgsqlVectorStore

    store = PgsqlVectorStore("postgresql://user:pass@host/db")
    fake_pool = AsyncMock()
    store._pool = fake_pool

    rows = asyncio.run(store.search([], user_id="u1", limit=3, threshold=0.6))

    assert rows == []
    fake_pool.fetch.assert_not_awaited()


def test_null_vector_store_returns_empty() -> None:
    from app.vector_store import NullVectorStore

    rows = asyncio.run(
        NullVectorStore().search(QUERY_EMBEDDING, user_id="u1", limit=3, threshold=0.6)
    )
    assert rows == []


def test_embed_sessions_returns_batch_embeddings() -> None:
    response = client.post(
        "/api/v1/search/embed_sessions",
        headers={"X-User-Id": "u1"},
        json={
            "sessions": [
                {"session_id": "s1", "text": "Release planning by Friday."},
                {"session_id": "s2", "text": "Benchmark harness setup."},
            ]
        },
    )

    assert response.status_code == 200
    data = response.json()
    assert data["dimension"] == DIMS
    assert [e["session_id"] for e in data["embeddings"]] == ["s1", "s2"]
    for entry in data["embeddings"]:
        assert entry["embedding"] == QUERY_EMBEDDING
        assert entry["dimension"] == DIMS


def test_embed_sessions_caps_batch_and_allows_empty_text() -> None:
    many = [{"session_id": f"s{i}", "text": ""} for i in range(75)]
    response = client.post(
        "/api/v1/search/embed_sessions",
        headers={"X-User-Id": "u1"},
        json={"sessions": many},
    )

    assert response.status_code == 200
    data = response.json()
    assert len(data["embeddings"]) == 50  # _MAX_BACKFILL_SESSIONS


def test_embed_sessions_empty_payload_returns_empty() -> None:
    response = client.post(
        "/api/v1/search/embed_sessions",
        headers={"X-User-Id": "u1"},
        json={"sessions": []},
    )

    assert response.status_code == 200
    data = response.json()
    assert data["embeddings"] == []
    assert data["dimension"] == 0


def test_embed_sessions_requires_auth() -> None:
    response = client.post(
        "/api/v1/search/embed_sessions",
        json={"sessions": [{"session_id": "s1", "text": "hello"}]},
    )
    assert response.status_code == 401


def test_embed_sessions_rejects_missing_session_id() -> None:
    response = client.post(
        "/api/v1/search/embed_sessions",
        headers={"X-User-Id": "u1"},
        json={"sessions": [{"text": "no id"}]},
    )
    assert response.status_code == 422
