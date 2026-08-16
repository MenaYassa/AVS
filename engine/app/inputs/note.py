"""Note input source: manual, user-authored notes (architecture §4.12).

A note is the simplest non-voice input: unlike images/PDFs there is no
preprocessing stage — the text is authored directly in the app and travels in
`meta["text"]`, so `input_ref` may be null (the same shape as the transcript
adapter). The adapter validates the text and normalizes it into a canonical
`InputDoc`, tagging the provenance (`note: True`) so downstream stages and
sync can tell a note session apart from a recording. Everything downstream is
input-agnostic, so nothing else changes.
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import InputDoc


class NoteInputSource:
    """Turns a user-authored note into a canonical `InputDoc`.

    The text is taken verbatim from `meta["text"]` and is always plain text,
    never Markdown (architecture §1.2). An optional user-chosen `title` is
    carried through as provenance, but the pipeline still generates the
    canonical title from content.
    """

    kind = "note"

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        text = meta.get("text")
        if not isinstance(text, str) or not text.strip():
            raise InvalidRequestError(
                "NoteInputSource requires meta['text']",
                details={"text_present": isinstance(text, str)},
            )
        return InputDoc(
            kind="note",
            text=text.strip(),
            meta={
                "source_ref": blob_ref or None,
                "note": True,
                "title": meta.get("title"),
                "language": meta.get("language"),
            },
        )
