"""Transcript input source: adapter for re-analyzing an edited transcript (§4.12).

Re-running analysis on a corrected transcript is input adapter #2. Unlike the
voice source it has no preprocessing stage — the text is already canonical, so
`ingest` simply validates/normalizes it into an `InputDoc`. `input_ref` may be
null; the text travels in `meta["text"]` (it is a small, user-authored string,
never an audio blob).
"""

from __future__ import annotations

from typing import Any

from app.errors import InvalidRequestError
from app.inputs.base import InputDoc


class TranscriptInputSource:
    """Turns an edited transcript into a canonical `InputDoc`.

    The text is taken verbatim from `meta["text"]` (the edited transcript) and
    is always plain text, never Markdown (architecture §1.2).
    """

    kind = "transcript"

    async def ingest(self, blob_ref: str, meta: dict[str, Any]) -> InputDoc:
        text = meta.get("text")
        if not isinstance(text, str) or not text.strip():
            raise InvalidRequestError(
                "TranscriptInputSource requires meta['text']",
                details={"text_present": isinstance(text, str)},
            )
        return InputDoc(
            kind="transcript",
            text=text.strip(),
            meta={
                "source_ref": blob_ref or None,
                "edited": True,
                "language": meta.get("language"),
            },
        )
