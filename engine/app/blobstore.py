"""Blob fetching for input adapters (architecture §4.12).

STT providers need audio bytes; `BlobFetcher` turns a `blob_ref` (e.g. a
Supabase Storage path like `sessions/<user_id>/<session_id>.m4a`) into bytes
without leaking any provider/storage specifics into the transcribers.

- `LocalBlobFetcher` resolves refs against `ENGINE_BLOB_ROOT` (dev/tests).
- `SupabaseBlobFetcher` downloads via the Storage REST API using the service
  role key (the deployed topology, §9).
"""

from __future__ import annotations

import hashlib
import logging
from pathlib import Path
from typing import Any, Protocol

from app.config import settings

logger = logging.getLogger(__name__)


class BlobNotFoundError(Exception):
    pass


class BlobFetcher(Protocol):
    async def fetch(self, blob_ref: str) -> bytes: ...


class LocalBlobFetcher:
    """Reads blobs from a local directory (hermetic dev + tests)."""

    def __init__(self, root: Path) -> None:
        self.root = root

    async def fetch(self, blob_ref: str) -> bytes:
        path = (self.root / blob_ref).resolve()
        root = self.root.resolve()
        if not path.is_relative_to(root):
            raise BlobNotFoundError(f"blob escapes blob root: {blob_ref}")
        try:
            return path.read_bytes()
        except OSError as exc:
            raise BlobNotFoundError(f"blob not found: {blob_ref}") from exc


class SupabaseBlobFetcher:
    """Downloads `blob_ref` from Supabase Storage with the service role key."""

    def __init__(
        self,
        *,
        base_url: str,
        service_role_key: str,
        client: Any = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._service_role_key = service_role_key
        self._client = client

    async def fetch(self, blob_ref: str) -> bytes:
        if not self._service_role_key:
            raise BlobNotFoundError(
                "SUPABASE_SERVICE_ROLE_KEY is not configured for blob download"
            )
        import httpx

        client = self._client
        close = False
        if client is None:
            client = httpx.AsyncClient(timeout=60.0)
            close = True
        try:
            response = await client.get(
                f"{self._base_url}/storage/v1/object/{blob_ref}",
                headers={"Authorization": f"Bearer {self._service_role_key}"},
            )
            response.raise_for_status()
            return response.content
        except httpx.HTTPError as exc:
            raise BlobNotFoundError(f"blob download failed: {blob_ref}: {exc}") from exc
        finally:
            if close:
                await client.aclose()


def get_blob_fetcher() -> BlobFetcher:
    if settings.blob_store == "supabase":
        return SupabaseBlobFetcher(
            base_url=settings.supabase_url,
            service_role_key=settings.supabase_service_role_key,
        )
    return LocalBlobFetcher(Path(settings.blob_root))


def fetch_blob(blob_ref: str) -> bytes:
    """Synchronous convenience for tests/scripts (async in the pipeline)."""
    import asyncio

    return asyncio.run(get_blob_fetcher().fetch(blob_ref))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
