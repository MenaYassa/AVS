"""Document input source: adapter #7 of the universal input pipeline (§4.12).

Preprocessing for an office/text document (docx, odt, rtf, txt, md, html,
csv, json, xml) is a parser. The source validates the blob's mime type against
the supported document set and delegates text extraction to the injected
parser provider — the same seam emails use. PDFs are deliberately NOT handled
here: they have their own adapter routed through OCR. Everything downstream
sees a canonical `InputDoc` and never assumes the input was audio.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import (
    DOCUMENT_MIME_TYPES,
    DocumentParserProvider,
    InputDoc,
)


class DocumentInputSource:
    """Turns an office/text document blob into a canonical `InputDoc`."""

    kind = "document"

    def __init__(self, provider: DocumentParserProvider) -> None:
        self._provider = provider

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        mime_type = meta.get("mime_type", "")
        if mime_type not in DOCUMENT_MIME_TYPES:
            raise InvalidRequestError(
                "DocumentInputSource requires a supported document mime type",
                details={
                    "mime_type": mime_type or None,
                    "supported": sorted(DOCUMENT_MIME_TYPES),
                },
            )

        result = await self._provider.parse(blob_ref, mime_type=mime_type)

        return InputDoc(
            kind="document",
            text=result.text,
            meta={
                "source_ref": blob_ref,
                "language": meta.get("language"),
                "mime_type": mime_type,
                "title": result.title,
                "parser_confidence": result.confidence,
                "parsed": True,
            },
        )
