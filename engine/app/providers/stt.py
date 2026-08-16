"""STT provider adapters (architecture §4.4).

Each transcriber maps provider-native transcript shapes into the canonical
`TranscriptionResult`. Blob bytes come from the injected `BlobFetcher`, never
from the adapter reading storage directly — so dev/local and Supabase layouts
swap without touching adapters (§4.12).

- `OpenAIWhisperSTT`: OpenAI `/audio/transcriptions`.
- `DeepgramSTT`: Deepgram `/v1/listen` (the engine always uses full audio,
  Deepgram streams are a later optimization).
- `AssemblyAISTT`: upload → submit → poll `/v2/transcript` (AssemblyAI has no
  one-shot audio endpoint).
"""

from __future__ import annotations

import asyncio
from typing import Any

import httpx
from app.blobstore import BlobFetcher
from app.inputs.base import TranscriptionResult
from app.providers.base import ProviderOutputError

DEFAULT_TIMEOUT = httpx.Timeout(120.0, connect=10.0)
AUDIO_MIME = "audio/mpeg"


def _client_or_shared(
    client: httpx.AsyncClient | None,
) -> tuple[httpx.AsyncClient, bool]:
    if client is not None:
        return client, False
    return httpx.AsyncClient(timeout=DEFAULT_TIMEOUT), True


class OpenAIWhisperSTT:
    """OpenAI's hosted Whisper transcription endpoint."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None,
        blob_fetcher: BlobFetcher,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._blob_fetcher = blob_fetcher
        self._client = client

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult:
        if not self._api_key:
            raise ProviderOutputError("OpenAI Whisper requires an API key")
        audio = await self._blob_fetcher.fetch(blob_ref)
        data: dict[str, str] = {"model": self.model}
        if language:
            data["language"] = language
        client, close = _client_or_shared(self._client)
        try:
            response = await client.post(
                f"{self._base_url}/audio/transcriptions",
                headers={"Authorization": f"Bearer {self._api_key}"},
                files={"file": (blob_ref, audio, AUDIO_MIME)},
                data=data,
            )
            response.raise_for_status()
            payload = response.json()
        finally:
            if close:
                await client.aclose()
        text = payload.get("text") if isinstance(payload, dict) else None
        if not text:
            raise ProviderOutputError("OpenAI Whisper returned empty transcript")
        return TranscriptionResult(
            text=text,
            language=payload.get("language") if isinstance(payload, dict) else None,
        )


class DeepgramSTT:
    """Deepgram `/v1/listen` with a generic audio file part."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None,
        blob_fetcher: BlobFetcher,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._blob_fetcher = blob_fetcher
        self._client = client

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult:
        if not self._api_key:
            raise ProviderOutputError("Deepgram requires an API key")
        audio = await self._blob_fetcher.fetch(blob_ref)
        params: dict[str, str] = {"model": self.model, "punctuate": "true"}
        if language:
            params["language"] = language
        client, close = _client_or_shared(self._client)
        try:
            response = await client.post(
                f"{self._base_url}/v1/listen",
                params=params,
                headers={"Authorization": f"Token {self._api_key}"},
                files={"audio": (blob_ref, audio, AUDIO_MIME)},
            )
            response.raise_for_status()
            payload = response.json()
        finally:
            if close:
                await client.aclose()
        try:
            alt = payload["results"]["channels"][0]["alternatives"][0]
        except (KeyError, IndexError, TypeError) as exc:
            raise ProviderOutputError(
                f"malformed Deepgram response: {exc}"
            ) from exc
        text = alt.get("transcript")
        if not text:
            raise ProviderOutputError("Deepgram returned empty transcript")
        return TranscriptionResult(
            text=text,
            language=alt.get("language") or language,
            confidence=alt.get("confidence"),
        )


class AssemblyAISTT:
    """AssemblyAI: upload audio → submit transcript job → poll to completion."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        api_key: str | None,
        blob_fetcher: BlobFetcher,
        client: httpx.AsyncClient | None = None,
        poll_interval: float = 2.0,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._api_key = api_key
        self._blob_fetcher = blob_fetcher
        self._client = client
        self._poll_interval = poll_interval

    async def _request(
        self,
        client: httpx.AsyncClient,
        method: str,
        path: str,
        *,
        json_body: dict[str, Any] | None = None,
        raw_body: bytes | None = None,
    ) -> dict[str, Any]:
        if not self._api_key:
            raise ProviderOutputError("AssemblyAI requires an API key")
        response = await client.request(
            method,
            f"{self._base_url}{path}",
            headers={"Authorization": f"Bearer {self._api_key}"},
            json=json_body,
            content=raw_body,
        )
        response.raise_for_status()
        return response.json()

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult:
        audio = await self._blob_fetcher.fetch(blob_ref)
        client, close = _client_or_shared(self._client)
        try:
            upload = await self._request(
                client, "POST", "/v2/upload", raw_body=audio
            )
            audio_url = upload.get("audio_url")
            if not audio_url:
                raise ProviderOutputError("AssemblyAI upload missing audio_url")
            body: dict[str, Any] = {
                "audio_url": audio_url,
                "speech_model": self.model,
            }
            if language:
                body["language_code"] = language
            submitted = await self._request(
                client, "POST", "/v2/transcript", json_body=body
            )
            transcript_id = submitted.get("id")
            if not transcript_id:
                raise ProviderOutputError(
                    "AssemblyAI transcript submission missing id"
                )
            result = await self._poll(client, transcript_id)
        finally:
            if close:
                await client.aclose()
        text = result.get("text")
        if not text:
            raise ProviderOutputError("AssemblyAI returned empty transcript")
        return TranscriptionResult(
            text=text,
            language=result.get("language_code") or language,
            confidence=result.get("confidence"),
        )

    async def _poll(
        self, client: httpx.AsyncClient, transcript_id: str
    ) -> dict[str, Any]:
        for _ in range(600):
            result = await self._request(
                client, "GET", f"/v2/transcript/{transcript_id}"
            )
            status = result.get("status")
            if status == "completed":
                return result
            if status == "error":
                raise ProviderOutputError(
                    f"AssemblyAI transcription failed: {result.get('error')}"
                )
            if self._poll_interval > 0:
                await asyncio.sleep(self._poll_interval)
        raise ProviderOutputError("AssemblyAI transcription timed out")
