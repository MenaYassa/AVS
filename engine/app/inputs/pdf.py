"""PDF input source: adapter #5 of the universal input pipeline (§4.12).

Preprocessing for a PDF is OCR (the real adapters may render pages then run
OCR; a placeholder fails jobs with a structured NOT_IMPLEMENTED error until
they land). The source validates the blob's mime type and delegates text
extraction to the injected OCR provider — the same seam images use.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import InputDoc, OcrProvider


class PdfInputSource:
    """Turns a PDF blob into a canonical `InputDoc` via OCR."""

    kind = "pdf"

    def __init__(self, provider: OcrProvider) -> None:
        self._provider = provider

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        mime_type = meta.get("mime_type", "")
        if mime_type != "application/pdf":
            raise InvalidRequestError(
                "PdfInputSource requires an application/pdf blob",
                details={"mime_type": mime_type or None},
            )

        result = await self._provider.extract_text(blob_ref, mime_type=mime_type)

        return InputDoc(
            kind="pdf",
            text=result.text,
            meta={
                "source_ref": blob_ref,
                "language": meta.get("language"),
                "mime_type": mime_type,
                "ocr_confidence": result.confidence,
                "extracted": True,
            },
        )
