"""Semantic search API for Phase 6 §6.1.

`POST /api/v1/search/semantic` embeds the query with the pipeline's
`EmbeddingProvider`, then returns the query embedding (so clients can rank
locally-stored vectors) alongside any pgvector results from the configured
vector store (§5.4). With no `ENGINE_DATABASE_URL`, `results` is empty but the
query embedding is still returned — the on-device local index (drift) is the
fallback retrieval path.
"""

from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends
from pydantic import BaseModel

from app.auth import authenticate
from app.providers.embedding import get_embedding_provider
from app.vector_store import get_vector_store

router = APIRouter(prefix="/api/v1/search", tags=["search"])


class SemanticSearchRequest(BaseModel):
    query: str
    limit: int = 10
    threshold: float = 0.7


class SemanticSearchResult(BaseModel):
    session_id: str
    title: Optional[str]
    summary: Optional[str]
    similarity: float


class SemanticSearchResponse(BaseModel):
    results: list[SemanticSearchResult]
    total: int
    query_embedding: list[float]
    dimension: int


class EmbedSessionInput(BaseModel):
    session_id: str
    text: str = ""


class EmbedSessionsRequest(BaseModel):
    sessions: list[EmbedSessionInput]


class EmbedSessionOutput(BaseModel):
    session_id: str
    embedding: list[float]
    dimension: int


class EmbedSessionsResponse(BaseModel):
    embeddings: list[EmbedSessionOutput]
    dimension: int


_MAX_BACKFILL_SESSIONS = 50


@router.post("/embed_sessions", response_model=EmbedSessionsResponse)
async def embed_sessions(
    body: EmbedSessionsRequest,
    user_id: str = Depends(authenticate),
) -> EmbedSessionsResponse:
    """Embed session content for local index backfill (§6.1).

    Returns the embedding for each supplied session so the client can persist
    vectors it has no cached copy of (e.g. sessions analyzed before the
    `embedding` stage shipped). No cross-session data: the payload is scoped to
    the authenticated user's own sessions, and the result carries no stored
    state server-side.
    """
    if not body.sessions:
        return EmbedSessionsResponse(embeddings=[], dimension=0)

    provider = get_embedding_provider()
    inputs = body.sessions[:_MAX_BACKFILL_SESSIONS]
    texts = [s.text for s in inputs]
    vectors = provider.embed_batch(texts)
    return EmbedSessionsResponse(
        embeddings=[
            EmbedSessionOutput(
                session_id=inputs[i].session_id,
                embedding=vectors[i],
                dimension=provider.dimensions,
            )
            for i in range(len(inputs))
        ],
        dimension=provider.dimensions,
    )


@router.post("/semantic", response_model=SemanticSearchResponse)
async def semantic_search(
    body: SemanticSearchRequest,
    user_id: str = Depends(authenticate),
) -> SemanticSearchResponse:
    """Search sessions by semantic similarity using pgvector.

    Embeds the query, then finds the nearest sessions by cosine similarity.
    """
    provider = get_embedding_provider()
    query_embedding = provider.embed(body.query.strip())
    store = get_vector_store()
    rows = await store.search(
        query_embedding,
        user_id=user_id,
        limit=body.limit,
        threshold=body.threshold,
    )
    return SemanticSearchResponse(
        results=[SemanticSearchResult(**row) for row in rows],
        total=len(rows),
        query_embedding=query_embedding,
        dimension=provider.dimensions,
    )
