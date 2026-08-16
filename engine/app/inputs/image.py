"""Image input source: adapter #4 of the universal input pipeline (§4.12).

Preprocessing for a photo/screenshot is OCR. The source only validates the
blob's mime type and delegates text extraction to the injected OCR provider,
so the same source works with any OCR backend (the placeholder fails jobs with
a structured NOT_IMPLEMENTED error until real adapters land). Everything
downstream sees a canonical `InputDoc` and never assumes the input was audio.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import InputDoc, OcrProvider


class ImageInputSource:
    """Turns an image blob into a canonical `InputDoc` via OCR."""

    kind = "image"

    def __init__(self, provider: OcrProvider) -> None:
        self._provider = provider

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        mime_type = meta.get("mime_type", "")
        if not mime_type.startswith("image/"):
            raise InvalidRequestError(
                "ImageInputSource requires an image blob",
                details={"mime_type": mime_type or None},
            )

        result = await self._provider.extract_text(blob_ref, mime_type=mime_type)

        return InputDoc(
            kind="image",
            text=result.text,
            meta={
                "source_ref": blob_ref,
                "language": meta.get("language"),
                "mime_type": mime_type,
                "ocr_confidence": result.confidence,
                "extracted": True,
            },
        )
