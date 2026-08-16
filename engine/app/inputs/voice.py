"""Voice input source: adapter #1 of the universal input pipeline (§4.12).

Preprocessing for voice is STT. The real STT provider adapters (Whisper,
Deepgram, AssemblyAI) land in Phase 2 (§2.2); until then a
`PlaceholderTranscriptionProvider` fails jobs with a structured
NOT_IMPLEMENTED error, consistent with the Phase 1 orchestrator.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError, JobFailedError
from app.inputs.base import (
    InputDoc,
    TranscriptionProvider,
    TranscriptionResult,
)


class PlaceholderTranscriptionProvider:
    """Phase 1 stand-in; replaced by real STT adapters in Phase 2."""

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult:
        raise JobFailedError(
            "STT providers are not wired yet (Phase 2).",
            code="NOT_IMPLEMENTED",
            details={"blob_ref": blob_ref, "language": language},
        )


class VoiceInputSource:
    """Turns an audio blob into a canonical `InputDoc`.

    The source only validates/normalizes metadata and delegates transcription
    to the injected provider, so the same source is used with any STT backend.
    """

    kind = "voice"

    def __init__(self, provider: TranscriptionProvider) -> None:
        self._provider = provider

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        mime_type = meta.get("mime_type", "")
        if not mime_type.startswith("audio/"):
            raise InvalidRequestError(
                "VoiceInputSource requires an audio blob",
                details={"mime_type": mime_type or None},
            )

        duration_sec = meta.get("duration_sec")
        if duration_sec is not None and duration_sec < 0:
            raise InvalidRequestError(
                "duration_sec must be non-negative",
                details={"duration_sec": duration_sec},
            )

        language = meta.get("language")
        result = await self._provider.transcribe(blob_ref, language=language)

        return InputDoc(
            kind="voice",
            text=result.text,
            meta={
                "source_ref": blob_ref,
                "language": result.language or language,
                "duration_sec": duration_sec,
                "mime_type": mime_type,
                "transcription_confidence": result.confidence,
            },
        )
