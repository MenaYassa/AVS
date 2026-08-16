"""Embedding/retrieval quality tests (§6.5).

Semantic search quality can't be validated against real model weights in
hermetic CI, so this module asserts the *stack's* quality properties with a
deterministic token-overlap embedding: texts sharing tokens embed closer in
cosine space, and the retrieval path (embed → rank → threshold → top-k) must
preserve that ordering end to end.

Sections:
- `TokenOverlapEmbeddingProvider` — deterministic, normalized, dimension-pinned.
- `MemoryVectorStore` — in-process stand-in for pgvector with the same protocol.
- Quality assertions: related-over-unrelated ranking, top-k, thresholds,
  user scoping, and the embedding stage's vector invariants.
- A semantic-search API test wired to the same quality stack (no network).
"""

from __future__ import annotations

import hashlib
import math

import pytest
from app.inputs.base import InputDoc
from app.main import app
from app.routers import search as search_module
from app.stages.context import StageContext, TokenBudget
from app.stages.embedding import EmbeddingStage
from app.stages.names import STAGE_CLEANUP, STAGE_VALIDATION
from fastapi.testclient import TestClient

client = TestClient(app)

DIMS = 64


def token_overlap_embedding(text: str) -> list[float]:
    """Bag-of-tokens embedding: each token maps to one coordinate (hashed),
    weighted by count, then L2-normalized. Cosine similarity therefore tracks
    how many tokens two texts share — deterministic and quality-assertable."""
    vector = [0.0] * DIMS
    for token in text.lower().split():
        index = int(hashlib.sha256(token.encode()).hexdigest(), 16) % DIMS
        vector[index] += 1.0
    norm = math.sqrt(sum(v * v for v in vector))
    if norm == 0.0:
        return vector
    return [v / norm for v in vector]


def cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (na * nb)


class TokenOverlapEmbeddingProvider:
    """Implements the `EmbeddingProvider` protocol (dimension pinned to DIMS)."""

    dimensions = DIMS

    def embed(self, text: str) -> list[float]:
        return token_overlap_embedding(text)

    def embed_batch(self, texts: list[str]) -> list[list[float]]:
        return [token_overlap_embedding(t) for t in texts]


class MemoryVectorStore:
    """Protocol-compatible pgvector stand-in with real cosine ranking."""

    def __init__(self, rows: list[dict]) -> None:
        self._rows = rows

    async def search(
        self,
        query_embedding: list[float],
        *,
        user_id: str,
        limit: int,
        threshold: float,
    ) -> list[dict]:
        scored: list[dict] = []
        for row in self._rows:
            if row["user_id"] != user_id:
                continue
            similarity = cosine(query_embedding, row["embedding"])
            if similarity >= threshold:
                scored.append(
                    {
                        "session_id": row["session_id"],
                        "title": row["title"],
                        "summary": row["summary"],
                        "similarity": round(similarity, 6),
                    }
                )
        scored.sort(key=lambda r: r["similarity"], reverse=True)
        return scored[:limit]


# A corpus where `release`/`launch`/`planning` sessions genuinely overlap with
# the query while distractor sessions share almost no tokens.
_QUERY = "release planning for the launch"
_SESSIONS = [
    {
        "session_id": "rel-1",
        "user_id": "u1",
        "title": "Release planning",
        "summary": "launch timeline",
        "text": "release planning launch timeline",
    },
    {
        "session_id": "rel-2",
        "user_id": "u1",
        "title": "Launch checklist",
        "summary": "release day plan",
        "text": "launch checklist release day plan",
    },
    {
        "session_id": "rel-3",
        "user_id": "u1",
        "title": "Quarterly plan",
        "summary": "planning cycle",
        "text": "planning cycle for next release",
    },
    {
        "session_id": "unrelated-1",
        "user_id": "u1",
        "title": "Grocery list",
        "summary": "eggs milk bread",
        "text": "eggs milk bread",
    },
    {
        "session_id": "unrelated-2",
        "user_id": "u1",
        "title": "Benchmark harness",
        "summary": "load testing infra",
        "text": "load testing infrastructure setup",
    },
    {
        "session_id": "other-user",
        "user_id": "u2",
        "title": "Release planning",
        "summary": "launch timeline",
        "text": "release planning launch timeline",
    },
]


def _store() -> MemoryVectorStore:
    rows = [
        {
            "session_id": s["session_id"],
            "user_id": s["user_id"],
            "title": s["title"],
            "summary": s["summary"],
            "embedding": token_overlap_embedding(s["text"]),
        }
        for s in _SESSIONS
    ]
    return MemoryVectorStore(rows)


async def test_embedding_reflects_token_overlap() -> None:
    """The harness itself must rank shared-token texts higher (otherwise every
    quality assertion below would be vacuous)."""
    query = token_overlap_embedding(_QUERY)
    related = token_overlap_embedding("release planning launch timeline")
    unrelated = token_overlap_embedding("eggs milk bread")
    assert cosine(query, related) > 0.5
    assert cosine(query, unrelated) < 0.1
    assert cosine(query, related) > cosine(query, unrelated)


async def test_retrieval_ranks_related_above_unrelated() -> None:
    results = await _store().search(
        token_overlap_embedding(_QUERY),
        user_id="u1",
        limit=10,
        threshold=0.0,
    )
    ids = [r["session_id"] for r in results]
    assert ids[:3] == ["rel-1", "rel-3", "rel-2"]
    assert set(ids[3:]) == {"unrelated-1", "unrelated-2"}
    assert results[0]["similarity"] >= results[-1]["similarity"]


async def test_retrieval_respects_top_k() -> None:
    results = await _store().search(
        token_overlap_embedding(_QUERY),
        user_id="u1",
        limit=2,
        threshold=0.0,
    )
    assert len(results) == 2
    assert results[0]["session_id"] == "rel-1"
    assert results[1]["session_id"] == "rel-3"


async def test_retrieval_threshold_filters_weak_matches() -> None:
    # A high threshold keeps only the strongest matches above the cutoff.
    store = _store()
    query = token_overlap_embedding(_QUERY)
    all_sims = [
        cosine(query, token_overlap_embedding(s["text"]))
        for s in _SESSIONS
        if s["user_id"] == "u1"
    ]
    threshold = max(all_sims) - 0.001
    results = await store.search(query, user_id="u1", limit=10, threshold=threshold)
    assert len(results) == 1
    assert results[0]["session_id"] == "rel-1"


async def test_retrieval_is_user_scoped() -> None:
    results = await _store().search(
        token_overlap_embedding(_QUERY),
        user_id="u2",
        limit=10,
        threshold=0.0,
    )
    assert [r["session_id"] for r in results] == ["other-user"]


def _validation_intermediates() -> dict:
    return {
        "title": "Release planning",
        "summary": "Launch timeline for the release.",
        "language": "en",
        "topics": [
            {
                "position": 0,
                "title": "Launch",
                "items": [{"content": "Finalize the launch checklist."}],
            }
        ],
    }


def _embedding_ctx() -> StageContext:
    ctx = StageContext(
        input_doc=InputDoc(
            kind="voice",
            text="raw",
            meta={"job_id": "job-1", "language": "en"},
        ),
        prompt_versions={STAGE_CLEANUP: 1},
        budget=TokenBudget(max_input_tokens=100_000, max_output_tokens=4096),
    )
    ctx.intermediates[STAGE_VALIDATION] = _validation_intermediates()
    return ctx


def test_embedding_stage_emits_normalized_dimensioned_vector() -> None:
    stage = EmbeddingStage()
    stage._provider = TokenOverlapEmbeddingProvider()

    output = stage.build(_embedding_ctx())

    assert output["dimension"] == DIMS
    assert output["text_length"] > 0
    assert len(output["embedding"]) == DIMS
    norm = math.sqrt(sum(v * v for v in output["embedding"]))
    assert norm == pytest.approx(1.0)
    assert output["embedding"] == token_overlap_embedding(
        "Release planning | Launch timeline for the release. | Launch | "
        "Finalize the launch checklist."
    )


def test_embedding_stage_returns_empty_for_missing_validation() -> None:
    ctx = _embedding_ctx()
    del ctx.intermediates[STAGE_VALIDATION]

    output = EmbeddingStage().build(ctx)

    assert output == {"embedding": [], "dimension": 0}


def test_semantic_search_endpoint_preserves_quality(
    monkeypatch,
) -> None:
    """The API path (embed query → store.search) keeps the same ranking."""
    store = _store()
    monkeypatch.setattr(
        search_module, "get_embedding_provider", TokenOverlapEmbeddingProvider
    )
    monkeypatch.setattr(search_module, "get_vector_store", lambda: store)

    response = client.post(
        "/api/v1/search/semantic",
        headers={"X-User-Id": "u1"},
        json={"query": _QUERY, "limit": 3, "threshold": 0.0},
    )

    assert response.status_code == 200
    data = response.json()
    assert [r["session_id"] for r in data["results"]] == ["rel-1", "rel-3", "rel-2"]
    assert data["dimension"] == DIMS
    assert data["query_embedding"] == token_overlap_embedding(_QUERY)
