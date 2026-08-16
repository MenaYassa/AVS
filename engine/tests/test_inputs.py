"""Universal input pipeline tests (architecture §4.12): InputSource contract,
voice adapter metadata normalization, placeholder STT, the transcript adapter
(re-analyzing an edited transcript), the note adapter (manual user-authored
text), the OCR-backed image/PDF adapters, the parser-backed email/document
adapters, the screenshot adapter (riding the OCR image path), and the registry."""

from __future__ import annotations

import pytest
from app.errors import InvalidRequestError, JobFailedError
from app.inputs import (
    DocumentInputSource,
    EmailInputSource,
    ImageInputSource,
    InputDoc,
    NoteInputSource,
    OcrResult,
    ParsedDocument,
    PdfInputSource,
    PlaceholderDocumentParserProvider,
    PlaceholderOcrProvider,
    PlaceholderTranscriptionProvider,
    ScreenshotInputSource,
    TranscriptInputSource,
    TranscriptionResult,
    VoiceInputSource,
)
from app.inputs.registry import get_input_source
from pydantic import ValidationError


class _FakeProvider:
    def __init__(
        self,
        text: str = "hello world",
        language: str | None = None,
        confidence: float | None = None,
        *,
        requested_languages: list[str | None] | None = None,
    ) -> None:
        self._text = text
        self._language = language
        self._confidence = confidence
        self.requested_languages = (
            requested_languages if requested_languages is not None else []
        )

    async def transcribe(
        self, blob_ref: str, *, language: str | None = None
    ) -> TranscriptionResult:
        self.requested_languages.append(language)
        return TranscriptionResult(
            text=self._text,
            language=self._language,
            confidence=self._confidence,
        )


class _FakeOcrProvider:
    def __init__(
        self,
        text: str = "extracted text",
        confidence: float | None = None,
    ) -> None:
        self._text = text
        self._confidence = confidence
        self.requested_mime_types: list[str | None] = []

    async def extract_text(
        self, blob_ref: str, *, mime_type: str | None = None
    ) -> OcrResult:
        self.requested_mime_types.append(mime_type)
        return OcrResult(text=self._text, confidence=self._confidence)


class _FakeParserProvider:
    def __init__(
        self,
        text: str = "parsed document text",
        title: str | None = None,
        confidence: float | None = None,
    ) -> None:
        self._text = text
        self._title = title
        self._confidence = confidence
        self.requested_mime_types: list[str | None] = []

    async def parse(
        self,
        blob_ref: str,
        *,
        mime_type: str | None = None,
        user_id: str | None = None,
    ) -> ParsedDocument:
        self.requested_mime_types.append(mime_type)
        return ParsedDocument(
            text=self._text, title=self._title, confidence=self._confidence
        )


async def test_voice_source_ingest_builds_canonical_doc() -> None:
    source = VoiceInputSource(_FakeProvider(language="en", confidence=0.94))

    doc = await source.ingest(
        "bucket/session-a/audio.webm",
        meta={
            "mime_type": "audio/webm",
            "duration_sec": 42,
            "language": "en",
        },
    )

    assert source.kind == "voice"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "voice"
    assert doc.text == "hello world"
    assert doc.meta == {
        "source_ref": "bucket/session-a/audio.webm",
        "language": "en",
        "duration_sec": 42,
        "mime_type": "audio/webm",
        "transcription_confidence": 0.94,
    }


async def test_voice_source_passes_language_and_falls_back() -> None:
    detected = _FakeProvider(language="fr")
    doc = await VoiceInputSource(detected).ingest("a.webm", {"mime_type": "audio/webm"})
    assert doc.meta["language"] == "fr"

    fallback = _FakeProvider(language=None)
    doc = await VoiceInputSource(fallback).ingest(
        "a.webm", {"mime_type": "audio/webm", "language": "de"}
    )
    assert doc.meta["language"] == "de"
    assert fallback.requested_languages == ["de"]


async def test_voice_source_rejects_non_audio_blob() -> None:
    source = VoiceInputSource(_FakeProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("doc.pdf", {"mime_type": "application/pdf"})
    assert exc.value.code == "INVALID_REQUEST"


async def test_voice_source_rejects_negative_duration() -> None:
    source = VoiceInputSource(_FakeProvider())

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.webm", {"mime_type": "audio/webm", "duration_sec": -1})


async def test_placeholder_provider_fails_structurally() -> None:
    source = VoiceInputSource(PlaceholderTranscriptionProvider())

    with pytest.raises(JobFailedError) as exc:
        await source.ingest("a.webm", {"mime_type": "audio/webm"})
    assert exc.value.code == "NOT_IMPLEMENTED"
    assert exc.value.details == {"blob_ref": "a.webm", "language": None}


def test_transcription_result_confidence_bounds() -> None:
    with pytest.raises(ValidationError):
        TranscriptionResult(text="x", confidence=1.5)


def test_registry_resolves_voice() -> None:
    assert get_input_source("voice").kind == "voice"


def test_registry_resolves_transcript() -> None:
    assert get_input_source("transcript").kind == "transcript"


def test_registry_resolves_note() -> None:
    assert get_input_source("note").kind == "note"


def test_registry_resolves_image_with_injected_ocr() -> None:
    source = get_input_source("image", ocr=_FakeOcrProvider())
    assert source.kind == "image"


def test_registry_resolves_screenshot_with_injected_ocr() -> None:
    source = get_input_source("screenshot", ocr=_FakeOcrProvider())
    assert source.kind == "screenshot"


def test_registry_resolves_pdf_with_injected_ocr() -> None:
    source = get_input_source("pdf", ocr=_FakeOcrProvider())
    assert source.kind == "pdf"


def test_registry_rejects_unknown_kind() -> None:
    with pytest.raises(InvalidRequestError) as exc:
        get_input_source("doc")
    assert exc.value.code == "INVALID_REQUEST"
    for kind in (
        "voice",
        "transcript",
        "note",
        "image",
        "pdf",
        "email",
        "document",
        "screenshot",
    ):
        assert kind in exc.value.details["supported"]


async def test_transcript_source_ingest_builds_canonical_doc() -> None:
    source = TranscriptInputSource()

    doc = await source.ingest(
        "session-a",
        meta={
            "text": "We should ship v2 by Friday.",
            "language": "en",
        },
    )

    assert source.kind == "transcript"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "transcript"
    assert doc.text == "We should ship v2 by Friday."
    assert doc.meta == {
        "source_ref": "session-a",
        "edited": True,
        "language": "en",
    }


async def test_transcript_source_trims_but_keeps_content() -> None:
    doc = await TranscriptInputSource().ingest(
        None, meta={"text": "  edited text  "}
    )
    assert doc.text == "edited text"
    assert doc.meta["source_ref"] is None


async def test_transcript_source_rejects_missing_text() -> None:
    source = TranscriptInputSource()

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("session-a", meta={})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest("session-a", meta={"text": "   "})


async def test_note_source_ingest_builds_canonical_doc() -> None:
    source = NoteInputSource()

    doc = await source.ingest(
        None,
        meta={
            "text": "Book flights and draft the agenda for the offsite.",
            "title": "Offsite prep",
            "language": "en",
        },
    )

    assert source.kind == "note"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "note"
    assert doc.text == "Book flights and draft the agenda for the offsite."
    assert doc.meta == {
        "source_ref": None,
        "note": True,
        "title": "Offsite prep",
        "language": "en",
    }


async def test_note_source_trims_but_keeps_content() -> None:
    doc = await NoteInputSource().ingest(None, meta={"text": "  a note  "})
    assert doc.text == "a note"
    assert doc.meta["note"] is True


async def test_note_source_omits_absent_title() -> None:
    doc = await NoteInputSource().ingest("some-ref", meta={"text": "hello"})
    assert doc.meta["title"] is None
    assert doc.meta["source_ref"] == "some-ref"


async def test_note_source_rejects_missing_text() -> None:
    source = NoteInputSource()

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest(None, meta={})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest(None, meta={"text": "   "})


async def test_image_source_ingest_builds_canonical_doc() -> None:
    source = ImageInputSource(
        _FakeOcrProvider(text="whiteboard notes", confidence=0.88)
    )

    doc = await source.ingest(
        "bucket/session-a/photo.png",
        meta={"mime_type": "image/png", "language": "en"},
    )

    assert source.kind == "image"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "image"
    assert doc.text == "whiteboard notes"
    assert doc.meta == {
        "source_ref": "bucket/session-a/photo.png",
        "language": "en",
        "mime_type": "image/png",
        "ocr_confidence": 0.88,
        "extracted": True,
    }


async def test_image_source_passes_mime_to_ocr() -> None:
    provider = _FakeOcrProvider()
    await ImageInputSource(provider).ingest(
        "a.png", {"mime_type": "image/png"}
    )
    assert provider.requested_mime_types == ["image/png"]


async def test_image_source_rejects_non_image_blob() -> None:
    source = ImageInputSource(_FakeOcrProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("doc.pdf", {"mime_type": "application/pdf"})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.mp3", {"mime_type": "audio/mp3"})


async def test_pdf_source_ingest_builds_canonical_doc() -> None:
    source = PdfInputSource(_FakeOcrProvider(text="invoice contents", confidence=0.9))

    doc = await source.ingest(
        "bucket/session-a/doc.pdf",
        meta={"mime_type": "application/pdf"},
    )

    assert source.kind == "pdf"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "pdf"
    assert doc.text == "invoice contents"
    assert doc.meta == {
        "source_ref": "bucket/session-a/doc.pdf",
        "language": None,
        "mime_type": "application/pdf",
        "ocr_confidence": 0.9,
        "extracted": True,
    }


async def test_pdf_source_rejects_non_pdf_blob() -> None:
    source = PdfInputSource(_FakeOcrProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("a.png", {"mime_type": "image/png"})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.pdf", {"mime_type": "text/plain"})


async def test_screenshot_source_rides_image_ocr_path_with_provenance() -> None:
    source = ScreenshotInputSource(
        _FakeOcrProvider(text="screen text", confidence=0.77)
    )

    doc = await source.ingest(
        "bucket/session-a/shot.png",
        meta={"mime_type": "image/png", "language": "en"},
    )

    assert source.kind == "screenshot"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "screenshot"
    assert doc.text == "screen text"
    assert doc.meta == {
        "source_ref": "bucket/session-a/shot.png",
        "language": "en",
        "mime_type": "image/png",
        "ocr_confidence": 0.77,
        "extracted": True,
        "screenshot": True,
    }


async def test_screenshot_source_passes_mime_to_ocr() -> None:
    provider = _FakeOcrProvider()
    await ScreenshotInputSource(provider).ingest(
        "a.png", {"mime_type": "image/png"}
    )
    assert provider.requested_mime_types == ["image/png"]


async def test_screenshot_source_rejects_non_image_blob() -> None:
    source = ScreenshotInputSource(_FakeOcrProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("doc.pdf", {"mime_type": "application/pdf"})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.eml", {"mime_type": "message/rfc822"})


async def test_placeholder_ocr_fails_structurally() -> None:
    source = ImageInputSource(PlaceholderOcrProvider())

    with pytest.raises(JobFailedError) as exc:
        await source.ingest("a.png", {"mime_type": "image/png"})
    assert exc.value.code == "NOT_IMPLEMENTED"
    assert exc.value.details == {"blob_ref": "a.png", "mime_type": "image/png"}


def test_ocr_result_confidence_bounds() -> None:
    with pytest.raises(ValidationError):
        OcrResult(text="x", confidence=1.5)


def test_parsed_document_confidence_bounds() -> None:
    with pytest.raises(ValidationError):
        ParsedDocument(text="x", confidence=1.5)


async def test_email_source_ingest_builds_canonical_doc() -> None:
    source = EmailInputSource(
        _FakeParserProvider(
            text="The v2 release is on Friday.",
            title="Re: v2 release",
            confidence=0.99,
        )
    )

    doc = await source.ingest(
        "bucket/session-a/inbox.eml",
        meta={"mime_type": "message/rfc822", "language": "en"},
    )

    assert source.kind == "email"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "email"
    assert doc.text == "The v2 release is on Friday."
    assert doc.meta == {
        "source_ref": "bucket/session-a/inbox.eml",
        "language": "en",
        "mime_type": "message/rfc822",
        "title": "Re: v2 release",
        "parser_confidence": 0.99,
        "parsed": True,
    }


async def test_email_source_accepts_application_eml_and_passes_mime() -> None:
    provider = _FakeParserProvider()
    await EmailInputSource(provider).ingest("a.eml", {"mime_type": "application/eml"})
    assert provider.requested_mime_types == ["application/eml"]


async def test_email_source_rejects_non_email_blob() -> None:
    source = EmailInputSource(_FakeParserProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("doc.txt", {"mime_type": "text/plain"})
    assert exc.value.code == "INVALID_REQUEST"

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.eml", {"mime_type": "application/pdf"})


async def test_document_source_ingest_builds_canonical_doc() -> None:
    source = DocumentInputSource(
        _FakeParserProvider(text="Quarterly budget attached.", title="Budget"),
    )

    doc = await source.ingest(
        "bucket/session-a/budget.docx",
        meta={
            "mime_type": (
                "application/vnd.openxmlformats-officedocument"
                ".wordprocessingml.document"
            )
        },
    )

    assert source.kind == "document"
    assert isinstance(doc, InputDoc)
    assert doc.kind == "document"
    assert doc.text == "Quarterly budget attached."
    assert doc.meta == {
        "source_ref": "bucket/session-a/budget.docx",
        "language": None,
        "mime_type": (
            "application/vnd.openxmlformats-officedocument"
            ".wordprocessingml.document"
        ),
        "title": "Budget",
        "parser_confidence": None,
        "parsed": True,
    }


async def test_document_source_passes_mime_to_parser() -> None:
    provider = _FakeParserProvider()
    await DocumentInputSource(provider).ingest("a.md", {"mime_type": "text/markdown"})
    assert provider.requested_mime_types == ["text/markdown"]


async def test_document_source_rejects_unsupported_mime() -> None:
    source = DocumentInputSource(_FakeParserProvider())

    with pytest.raises(InvalidRequestError) as exc:
        await source.ingest("a.pdf", {"mime_type": "application/pdf"})
    assert exc.value.code == "INVALID_REQUEST"
    assert "supported" in exc.value.details

    with pytest.raises(InvalidRequestError):
        await source.ingest("a.mp3", {"mime_type": "audio/mp3"})


async def test_placeholder_parser_fails_structurally() -> None:
    source = EmailInputSource(PlaceholderDocumentParserProvider())

    with pytest.raises(JobFailedError) as exc:
        await source.ingest("a.eml", {"mime_type": "message/rfc822"})
    assert exc.value.code == "NOT_IMPLEMENTED"
    assert exc.value.details == {
        "blob_ref": "a.eml",
        "mime_type": "message/rfc822",
    }


def test_registry_resolves_email_with_injected_parser() -> None:
    source = get_input_source("email", parser=_FakeParserProvider())
    assert source.kind == "email"


def test_registry_resolves_document_with_injected_parser() -> None:
    source = get_input_source("document", parser=_FakeParserProvider())
    assert source.kind == "document"
