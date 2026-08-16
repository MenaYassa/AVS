"""Screenshot input source: adapter #8 of the universal input pipeline (§4.12).

Screenshots ride the image/OCR path: a screen capture is just an image, so this
adapter delegates mime validation and text extraction to the OCR provider via
`ImageInputSource` and only adds provenance (`kind: "screenshot"`, meta
`screenshot: True`) so downstream stages can distinguish a screen capture from
a photo without any OCR specialization. The device-gated *capture* itself
happens on the client; the engine only ever ingests the resulting blob.
"""

from __future__ import annotations

from typing import Any

from app.inputs.base import InputDoc
from app.inputs.image import ImageInputSource


class ScreenshotInputSource(ImageInputSource):
    """Turns a screenshot blob into a canonical `InputDoc` via OCR."""

    kind = "screenshot"

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        doc = await super().ingest(blob_ref, meta)
        return InputDoc(
            kind=self.kind,
            text=doc.text,
            meta={**doc.meta, "screenshot": True},
        )
