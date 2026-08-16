"""Universal input pipeline (architecture §4.12).

Voice is adapter #1; transcript (edited-transcript re-analysis) is adapter #2;
note (manual user-authored text) is adapter #3; image and PDF (OCR-backed) are
adapters #4 and #5; email and document (parser-backed) are adapters #6 and #7;
screenshot (OCR-backed, rides the image path) is adapter #8. `InputSource` is
the seam every input type implements. Downstream stages only ever see a
canonical `InputDoc` — they never assume the input was audio.
"""

from __future__ import annotations

from app.inputs.base import (
    DOCUMENT_MIME_TYPES,
    EMAIL_MIME_TYPES,
    DocumentParserProvider,
    InputDoc,
    InputSource,
    OcrProvider,
    OcrResult,
    ParsedDocument,
    TranscriptionProvider,
    TranscriptionResult,
)
from app.inputs.document import DocumentInputSource
from app.inputs.email import EmailInputSource
from app.inputs.image import ImageInputSource
from app.inputs.note import NoteInputSource
from app.inputs.ocr import PlaceholderOcrProvider
from app.inputs.parsers import (
    PlaceholderDocumentParserProvider,
    StdlibDocumentParser,
)
from app.inputs.pdf import PdfInputSource
from app.inputs.registry import get_input_source
from app.inputs.screenshot import ScreenshotInputSource
from app.inputs.transcript import TranscriptInputSource
from app.inputs.voice import PlaceholderTranscriptionProvider, VoiceInputSource

__all__ = [
    "DOCUMENT_MIME_TYPES",
    "DocumentInputSource",
    "DocumentParserProvider",
    "EMAIL_MIME_TYPES",
    "EmailInputSource",
    "ImageInputSource",
    "InputDoc",
    "InputSource",
    "NoteInputSource",
    "OcrProvider",
    "OcrResult",
    "ParsedDocument",
    "PdfInputSource",
    "PlaceholderDocumentParserProvider",
    "PlaceholderOcrProvider",
    "PlaceholderTranscriptionProvider",
    "ScreenshotInputSource",
    "StdlibDocumentParser",
    "TranscriptionProvider",
    "TranscriptionResult",
    "TranscriptInputSource",
    "VoiceInputSource",
    "get_input_source",
]
