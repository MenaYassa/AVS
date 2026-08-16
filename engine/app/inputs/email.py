"""Email input source: adapter #6 of the universal input pipeline (§4.12).

Preprocessing for an email (.eml) is a document parser. The source validates
the blob's mime type and delegates text extraction to the injected parser
provider, mirroring how images/PDFs use OCR. The parser's structured title
(email subject) is carried through as provenance; everything downstream sees a
canonical `InputDoc` and never assumes the input was audio.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import (
    EMAIL_MIME_TYPES,
    DocumentParserProvider,
    InputDoc,
)


class EmailInputSource:
    """Turns an .eml blob into a canonical `InputDoc` via a parser."""

    kind = "email"

    def __init__(self, provider: DocumentParserProvider) -> None:
        self._provider = provider

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        mime_type = meta.get("mime_type", "")
        if mime_type not in EMAIL_MIME_TYPES:
            raise InvalidRequestError(
                "EmailInputSource requires an email message blob",
                details={"mime_type": mime_type or None},
            )

        result = await self._provider.parse(blob_ref, mime_type=mime_type)

        return InputDoc(
            kind="email",
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
