"""Document parser providers (architecture §4.12, §4.4).

Emails and office/text documents need a parsing step before the shared
pipeline — the same seam role STT plays for voice and OCR for images/PDFs.
`StdlibDocumentParser` extracts plain text using only the standard library
(`email`, `zipfile`, `xml.etree`, `html.parser`), so document input works
hermetically with no extra dependencies. A `PlaceholderDocumentParserProvider`
stays registered for symmetry so Phase 2 adapters can be swapped in by name.

Text always leaves parsers as plain text, never Markdown (§1.2).
"""

from __future__ import annotations

import email.header
import io
from email.parser import BytesParser
from email.policy import default as email_policy
from html.parser import HTMLParser
from typing import Any
from zipfile import ZipFile

from app.blobstore import BlobFetcher, BlobNotFoundError
from app.errors import JobFailedError
from app.inputs.base import (
    DOCUMENT_MIME_TYPES,
    EMAIL_MIME_TYPES,
    ParsedDocument,
)
from app.providers.base import ProviderOutputError

_DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
_ODT_MIME = "application/vnd.oasis.opendocument.text"


def _decode(raw: bytes) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def _plain_text(raw: bytes) -> str:
    text = _decode(raw).lstrip("\ufeff")
    return "\n".join(line.strip() for line in text.splitlines())


class _TextStripper(HTMLParser):
    """Collects visible text from HTML; skips script/style, captures <title>."""

    _SKIP = frozenset({"script", "style", "head", "noscript"})
    _BREAKS = frozenset(
        {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}
    )

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._lines: list[str] = []
        self._buffer: list[str] = []
        self.title: str | None = None
        self._skip_depth = 0
        self._in_title = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "title":
            self._in_title += 1
            return
        if tag in self._SKIP:
            self._skip_depth += 1
        elif tag in self._BREAKS:
            self._flush()
        elif tag in ("td", "th"):
            self._buffer.append(" ")

    def handle_endtag(self, tag: str) -> None:
        if tag == "title" and self._in_title:
            self._in_title -= 1
        elif tag in self._SKIP and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title = data.strip()
            return
        if self._skip_depth:
            return
        self._buffer.append(data)

    def _flush(self) -> None:
        line = "".join(self._buffer).strip()
        if line:
            self._lines.append(line)
        self._buffer.clear()

    def text(self) -> str:
        self._flush()
        return "\n".join(self._lines)


def _strip_html(raw: bytes) -> tuple[str, str | None]:
    parser = _TextStripper()
    parser.feed(_decode(raw))
    return parser.text(), parser.title


def _decode_header(value: Any) -> str | None:
    if value is None:
        return None
    try:
        parts = email.header.decode_header(value)
        decoded = "".join(
            part.decode(enc or "utf-8", "replace") if isinstance(part, bytes) else part
            for part, enc in parts
        )
    except Exception:  # noqa: BLE001
        decoded = str(value)
    return decoded.strip() or None


def _email_plain_text(message: Any) -> str:
    body = message.get_body(preferencelist=("plain",))
    if body is not None and body.get_content_type() == "text/plain":
        return body.get_content().strip()
    parts: list[str] = []
    for part in message.walk():
        if not part.is_multipart() and part.get_content_type() == "text/plain":
            parts.append(part.get_content().strip())
    if parts:
        return "\n\n".join(parts)
    for part in message.walk():
        if not part.is_multipart() and part.get_content_type() == "text/html":
            text, _ = _strip_html(part.get_payload(decode=True) or b"")
            if text:
                return text
    return ""


def _parse_email(raw: bytes) -> tuple[str, str | None]:
    message = BytesParser(policy=email_policy).parsebytes(raw)
    return _email_plain_text(message), _decode_header(message["Subject"])


def _strip_rtf(raw: bytes) -> str:
    """Minimal RTF-to-text: drops control words/escapes, keeps text runs."""
    text = _decode(raw)
    out: list[str] = []
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            i += 1
            if i >= len(text):
                break
            esc = text[i]
            if esc == "'" and i + 2 < len(text):
                try:
                    out.append(bytes.fromhex(text[i + 1 : i + 3]).decode("latin-1"))
                except ValueError:
                    pass
                i += 3
                continue
            if esc in ("{", "}", "\\"):
                out.append(esc)
                i += 1
                continue
            j = i
            while j < len(text) and (
                text[j].isalpha() or text[j].isdigit() or text[j] == "-"
            ):
                j += 1
            word = text[i:j]
            if word.startswith("par") or word == "line" or word.startswith("page"):
                out.append("\n")
            elif word == "tab":
                out.append("\t")
            elif word.startswith(("fonttbl", "colortbl", "stylesheet")):
                # Skip the whole table group so its text never leaks.
                depth = 1
                while i < len(text) and depth:
                    ch = text[i]
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                    i += 1
                continue
            if j < len(text) and text[j] == " ":
                j += 1
            i = j
            continue
        if ch in "{}\n":
            i += 1
            continue
        out.append(ch)
        i += 1
    return _plain_text("".join(out).encode("utf-8", "replace"))


def _xml_paragraphs(raw: bytes) -> str:
    """Word/text-document XML → paragraph-per-line plain text."""
    import xml.etree.ElementTree as ET

    root = ET.fromstring(raw)
    blocks: list[str] = []
    buffer: list[str] = []

    def local(el: ET.Element) -> str:
        return el.tag.rsplit("}", 1)[-1]

    def flush() -> None:
        line = "".join(buffer).strip()
        if line:
            blocks.append(line)
        buffer.clear()

    def walk(el: ET.Element) -> None:
        if el.text:
            buffer.append(el.text)
        for child in el:
            walk(child)
            if local(child) == "p":
                flush()
        if el.tail:
            buffer.append(el.tail)

    walk(root)
    flush()
    return "\n".join(blocks)


def _read_zip_text(raw: bytes, member: str) -> bytes:
    with ZipFile(io.BytesIO(raw)) as zf:
        return zf.read(member)


class PlaceholderDocumentParserProvider:
    """Phase 1 stand-in; replaced by real parsers in Phase 2.

    The stdlib parser is already real; this exists so jobs fail with a
    structured NOT_IMPLEMENTED when a deployment selects a provider that has
    not been registered yet.
    """

    async def parse(
        self,
        blob_ref: str,
        *,
        mime_type: str | None = None,
        user_id: str | None = None,
    ) -> ParsedDocument:
        raise JobFailedError(
            "Document parsers are not wired yet (Phase 2).",
            code="NOT_IMPLEMENTED",
            details={"blob_ref": blob_ref, "mime_type": mime_type},
        )


class StdlibDocumentParser:
    """Pure-stdlib document/email parser (works hermetically, no deps)."""

    def __init__(self, *, blob_fetcher: BlobFetcher) -> None:
        self._blob_fetcher = blob_fetcher

    async def parse(
        self,
        blob_ref: str,
        *,
        mime_type: str | None = None,
        user_id: str | None = None,
    ) -> ParsedDocument:
        if mime_type not in EMAIL_MIME_TYPES and mime_type not in DOCUMENT_MIME_TYPES:
            raise ProviderOutputError(
                f"unsupported document mime type: {mime_type or '(none)'}"
            )
        try:
            raw = await self._blob_fetcher.fetch(blob_ref)
        except BlobNotFoundError as exc:
            raise ProviderOutputError(str(exc)) from exc
        try:
            return self._parse_raw(raw, mime_type)
        except Exception as exc:  # noqa: BLE001
            raise ProviderOutputError(
                f"failed to parse {mime_type or blob_ref}: {exc}"
            ) from exc

    def _parse_raw(self, raw: bytes, mime_type: str | None) -> ParsedDocument:
        if mime_type in EMAIL_MIME_TYPES:
            text, title = _parse_email(raw)
            return ParsedDocument(text=text, title=title, confidence=1.0)
        if mime_type == "text/html":
            text, title = _strip_html(raw)
            return ParsedDocument(text=text, title=title, confidence=1.0)
        if mime_type == "application/rtf":
            return ParsedDocument(text=_strip_rtf(raw), confidence=1.0)
        if mime_type == _DOCX_MIME:
            return ParsedDocument(
                text=_xml_paragraphs(_read_zip_text(raw, "word/document.xml")),
                confidence=1.0,
            )
        if mime_type == _ODT_MIME:
            return ParsedDocument(
                text=_xml_paragraphs(_read_zip_text(raw, "content.xml")),
                confidence=1.0,
            )
        return ParsedDocument(text=_plain_text(raw), confidence=1.0)
