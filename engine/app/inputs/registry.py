"""Input-source registry: kind → InputSource (architecture §4.12).

Voice is adapter #1; transcript (edited-transcript re-analysis) is adapter #2;
note (manual, user-authored text) is adapter #3; image and PDF (OCR-backed)
are adapters #4 and #5; email and document (parser-backed) are adapters #6 and
#7; screenshot (OCR-backed, rides the image path) is adapter #8. Voice's STT
provider, the OCR providers, and the document parsers are resolved from the
provider registry (§4.4), so tests and P2-B adapters register providers without
touching the orchestrator. New input kinds add a factory here and nothing
downstream changes.
"""

from __future__ import annotations

from app.errors import InvalidRequestError
from app.inputs.base import (
    DocumentParserProvider,
    InputSource,
    OcrProvider,
    TranscriptionProvider,
)
from app.inputs.document import DocumentInputSource
from app.inputs.email import EmailInputSource
from app.inputs.image import ImageInputSource
from app.inputs.note import NoteInputSource
from app.inputs.pdf import PdfInputSource
from app.inputs.screenshot import ScreenshotInputSource
from app.inputs.transcript import TranscriptInputSource
from app.inputs.voice import VoiceInputSource
from app.providers.registry import get_ocr, get_parser, get_transcriber


def _voice_source(transcriber: TranscriptionProvider | None) -> VoiceInputSource:
    provider = transcriber if transcriber is not None else get_transcriber()
    return VoiceInputSource(provider)


def _document_source(
    kind: str,
    provider: OcrProvider | None,
    *,
    name: str | None,
    user_id: str | None,
) -> ImageInputSource | PdfInputSource | ScreenshotInputSource:
    ocr = provider if provider is not None else get_ocr(name, user_id=user_id)
    if kind == "image":
        return ImageInputSource(ocr)
    if kind == "screenshot":
        return ScreenshotInputSource(ocr)
    return PdfInputSource(ocr)


def _parsed_source(
    kind: str,
    provider: DocumentParserProvider | None,
    *,
    name: str | None,
    user_id: str | None,
) -> EmailInputSource | DocumentInputSource:
    parser = provider if provider is not None else get_parser(name, user_id=user_id)
    if kind == "email":
        return EmailInputSource(parser)
    return DocumentInputSource(parser)


def get_input_source(
    kind: str,
    *,
    stt_provider: str | None = None,
    user_id: str | None = None,
    transcriber: TranscriptionProvider | None = None,
    ocr_provider: str | None = None,
    ocr: OcrProvider | None = None,
    parser_provider: str | None = None,
    parser: DocumentParserProvider | None = None,
) -> InputSource:
    if kind == "voice":
        provider = (
            transcriber
            if transcriber is not None
            else get_transcriber(stt_provider, user_id=user_id)
        )
        return VoiceInputSource(provider)
    if kind == "transcript":
        return TranscriptInputSource()
    if kind == "note":
        return NoteInputSource()
    if kind in ("image", "pdf", "screenshot"):
        return _document_source(kind, ocr, name=ocr_provider, user_id=user_id)
    if kind in ("email", "document"):
        return _parsed_source(kind, parser, name=parser_provider, user_id=user_id)
    raise InvalidRequestError(
        f"Unsupported input source kind: {kind!r}",
        details={
            "supported": [
                "voice",
                "transcript",
                "note",
                "image",
                "pdf",
                "email",
                "document",
                "screenshot",
            ]
        },
    )
