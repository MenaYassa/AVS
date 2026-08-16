"""Real stdlib document parser tests (architecture §4.12): plain text,
markdown, HTML (title + visible text), emails (subject + body), RTF, DOCX and
ODT zip fixtures, and structured errors for unsupported/missing blobs. All
fixtures are built in memory under a temp blob root — fully hermetic."""

from __future__ import annotations

import io
import zipfile

import pytest
from app.blobstore import BlobFetcher, BlobNotFoundError
from app.inputs.parsers import StdlibDocumentParser
from app.providers.base import ProviderOutputError

_DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
_ODT_MIME = "application/vnd.oasis.opendocument.text"


class _StaticFetcher(BlobFetcher):
    def __init__(self, blobs: dict[str, bytes]) -> None:
        self._blobs = blobs

    async def fetch(self, blob_ref: str) -> bytes:
        if blob_ref not in self._blobs:
            raise BlobNotFoundError(f"blob not found: {blob_ref}")
        return self._blobs[blob_ref]


def _parser(blobs: dict[str, bytes]) -> StdlibDocumentParser:
    return StdlibDocumentParser(blob_fetcher=_StaticFetcher(blobs))


def _docx_bytes(paragraphs: list[str]) -> bytes:
    xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        + "".join(f"<w:p><w:r><w:t>{p}</w:t></w:r></w:p>" for p in paragraphs)
        + "</w:document>"
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("word/document.xml", xml)
    return buffer.getvalue()


def _odt_bytes(paragraphs: list[str]) -> bytes:
    xml = (
        '<?xml version="1.0" encoding="UTF-8"?>'
        "<office:document-content "
        'xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
        'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">'
        "<office:body><office:text>"
        + "".join(f"<text:p>{p}</text:p>" for p in paragraphs)
        + "</office:text></office:body></office:document-content>"
    )
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("content.xml", xml)
    return buffer.getvalue()


async def test_plain_text() -> None:
    parser = _parser({"a.txt": b"  hello world\nsecond line\n"})
    result = await parser.parse("a.txt", mime_type="text/plain")
    assert result.text == "hello world\nsecond line"
    assert result.confidence == 1.0


async def test_markdown_is_kept_plain() -> None:
    parser = _parser({"a.md": "# Heading\n\nbody text".encode()})
    result = await parser.parse("a.md", mime_type="text/markdown")
    assert result.text == "# Heading\n\nbody text"


async def test_html_strips_markup_and_keeps_title() -> None:
    html = (
        "<html><head><title>Quarterly Review</title></head><body>"
        "<h1>Budget</h1><p>Numbers attached.</p>"
        "<script>window.x = 1;</script><style>.a{}</style>"
        "</body></html>"
    ).encode()
    parser = _parser({"a.html": html})
    result = await parser.parse("a.html", mime_type="text/html")
    assert result.title == "Quarterly Review"
    assert result.text == "Budget\nNumbers attached."


async def test_email_extracts_subject_and_plain_body() -> None:
    eml = (
        "From: Ada <ada@example.com>\n"
        "To: user@example.com\n"
        "Subject: Re: v2 release\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "\n"
        "The v2 release is on Friday.\n"
    ).encode()
    parser = _parser({"inbox.eml": eml})
    result = await parser.parse("inbox.eml", mime_type="message/rfc822")
    assert result.title == "Re: v2 release"
    assert result.text == "The v2 release is on Friday."


async def test_email_falls_back_to_html_body() -> None:
    eml = (
        "From: Ada <ada@example.com>\n"
        "Subject: No plain text\n"
        'Content-Type: text/html; charset="utf-8"\n'
        "\n"
        "<html><body><p>Only HTML here.</p></body></html>\n"
    ).encode()
    parser = _parser({"inbox.eml": eml})
    result = await parser.parse("inbox.eml", mime_type="message/rfc822")
    assert result.title == "No plain text"
    assert result.text == "Only HTML here."


async def test_email_decodes_encoded_word_subject() -> None:
    eml = (
        "From: Ada <ada@example.com>\n"
        "Subject: =?utf-8?q?Budget_=C3=A4nderung?=\n"
        "Content-Type: text/plain; charset=utf-8\n"
        "\n"
        "Body\n"
    ).encode()
    parser = _parser({"inbox.eml": eml})
    result = await parser.parse("inbox.eml", mime_type="application/eml")
    assert result.title == "Budget änderung"


async def test_rtf_extracts_text() -> None:
    rtf = (
        b"{\\rtf1\\ansi{\\fonttbl{\\f0 Times New Roman;}}"
        b"\\f0\\fs24 Hello world\\par second line}"
    )
    parser = _parser({"a.rtf": rtf})
    result = await parser.parse("a.rtf", mime_type="application/rtf")
    assert result.text == "Hello world\nsecond line"


async def test_docx_extracts_paragraphs() -> None:
    parser = _parser({"a.docx": _docx_bytes(["First paragraph.", "Second paragraph."])})
    result = await parser.parse("a.docx", mime_type=_DOCX_MIME)
    assert result.text == "First paragraph.\nSecond paragraph."


async def test_odt_extracts_paragraphs() -> None:
    parser = _parser({"a.odt": _odt_bytes(["Para one.", "Para two."])})
    result = await parser.parse("a.odt", mime_type=_ODT_MIME)
    assert result.text == "Para one.\nPara two."


async def test_unsupported_mime_is_a_structured_provider_error() -> None:
    parser = _parser({"a.pdf": b"%PDF"})
    with pytest.raises(ProviderOutputError) as exc:
        await parser.parse("a.pdf", mime_type="application/pdf")
    assert "unsupported document mime type" in str(exc.value)


async def test_missing_blob_is_a_structured_provider_error() -> None:
    parser = _parser({})
    with pytest.raises(ProviderOutputError):
        await parser.parse("missing.txt", mime_type="text/plain")


async def test_corrupt_zip_is_a_structured_provider_error() -> None:
    parser = _parser({"bad.docx": b"not a zip"})
    with pytest.raises(ProviderOutputError):
        await parser.parse("bad.docx", mime_type=_DOCX_MIME)
