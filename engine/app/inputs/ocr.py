"""Placeholder OCR provider (architecture §4.12, §4.4).

Images and PDFs share one preprocessing seam — OCR. The real adapters
(Tesseract, cloud OCR) land later; until then a `PlaceholderOcrProvider` fails
jobs with a structured NOT_IMPLEMENTED error, consistent with the Phase 1
orchestrator and the voice adapter's placeholder STT.
"""

from __future__ import annotations

from app.errors import JobFailedError
from app.inputs.base import OcrResult


class PlaceholderOcrProvider:
    """Phase 1 stand-in; replaced by real OCR adapters in Phase 2."""

    async def extract_text(
        self, blob_ref: str, *, mime_type: str | None = None
    ) -> OcrResult:
        raise JobFailedError(
            "OCR providers are not wired yet (Phase 2).",
            code="NOT_IMPLEMENTED",
            details={"blob_ref": blob_ref, "mime_type": mime_type},
        )
