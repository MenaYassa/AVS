"""Canonical input document + input-source contract (architecture §4.12)."""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable

from pydantic import BaseModel, ConfigDict, Field


class InputDoc(BaseModel):
    """Normalized text + metadata handed to the orchestrator (§4.2).

    `meta` carries source provenance: `source_ref` (blob location), language,
    duration, mime type, and per-kind extras. Text is always plain, never
    Markdown (architecture §1.2).
    """

    model_config = ConfigDict(extra="allow")

    kind: str
    text: str
    meta: dict[str, Any] = Field(default_factory=dict)


class TranscriptionResult(BaseModel):
    """STT output consumed by the voice adapter."""

    text: str
    language: str | None = None
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


@runtime_checkable
class TranscriptionProvider(Protocol):
    """Kind-specific preprocessing seam (architecture §4.4)."""

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult: ...


class OcrResult(BaseModel):
    """OCR output consumed by the image/PDF adapters."""

    text: str
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


@runtime_checkable
class OcrProvider(Protocol):
    """Text-extraction seam for images and PDFs (architecture §4.12)."""

    async def extract_text(
        self, blob_ref: str, *, mime_type: str | None = None
    ) -> OcrResult: ...


EMAIL_MIME_TYPES = frozenset({"message/rfc822", "application/eml"})

DOCUMENT_MIME_TYPES = frozenset(
    {
        "text/plain",
        "text/markdown",
        "text/csv",
        "text/xml",
        "application/xml",
        "application/json",
        "text/html",
        "application/rtf",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.oasis.opendocument.text",
    }
)


class ParsedDocument(BaseModel):
    """Parser output consumed by the email/document adapters."""

    text: str
    title: str | None = None
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)


@runtime_checkable
class DocumentParserProvider(Protocol):
    """Parsing seam for emails and office/text documents (architecture §4.12).

    Same role as STT for voice and OCR for images/PDFs: the adapter validates
    the blob and delegates text extraction here. The stdlib parser is real and
    dependency-free; a placeholder stays available for Phase 2 adapters.
    """

    async def parse(
        self,
        blob_ref: str,
        *,
        mime_type: str | None = None,
        user_id: str | None = None,
    ) -> ParsedDocument: ...


@runtime_checkable
class InputSource(Protocol):
    """Every input type implements `ingest` → one canonical `InputDoc`.

    Later inputs (images/PDFs/email/docs) add a preprocessing step and nothing
    downstream changes.
    """

    kind: str

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc: ...
