"""OCR/PDF parsing goldens (§6.5).

Real binary documents committed under `tests/fixtures/documents/` are parsed
with the production `StdlibDocumentParser` + `LocalBlobFetcher` and asserted
against exact expected text/title — a versioned golden for the parser seam.

The `sample.pdf` golden documents the OCR boundary: PDFs are *not* documents
for the parser (they ride the OCR seam), so the parser rejects them and the
`PlaceholderOcrProvider` fails structurally. Real OCR text-extraction goldens
land with the Phase 2 OCR adapter; this fixture pins the contract they will
validate against.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from app.blobstore import LocalBlobFetcher
from app.errors import JobFailedError
from app.inputs.ocr import PlaceholderOcrProvider
from app.inputs.parsers import StdlibDocumentParser
from app.providers.base import ProviderOutputError

_FIXTURES = Path(__file__).parent / "fixtures" / "documents"
_DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
_ODT_MIME = "application/vnd.oasis.opendocument.text"


def _parser() -> StdlibDocumentParser:
    return StdlibDocumentParser(blob_fetcher=LocalBlobFetcher(_FIXTURES))


async def _parse(name: str, mime_type: str):
    return await _parser().parse(name, mime_type=mime_type)


async def test_docx_golden_extracts_paragraphs() -> None:
    result = await _parse("meeting.docx", _DOCX_MIME)
    assert result.title is None
    assert result.text == (
        "Quarterly review call\n"
        "Budget approved for Q3.\n"
        "Action: finalize roadmap."
    )


async def test_odt_golden_extracts_paragraphs() -> None:
    result = await _parse("notes.odt", _ODT_MIME)
    assert result.text == (
        "Standup notes\n"
        "Frontend tests are green.\n"
        "Engine parity contract holds."
    )


async def test_email_golden_extracts_subject_and_body() -> None:
    result = await _parse("inbox.eml", "message/rfc822")
    assert result.title == "Re: v2 release"
    assert result.text == "The v2 release ships on Friday."


async def test_rtf_golden_extracts_text() -> None:
    result = await _parse("invoice.rtf", "application/rtf")
    assert result.text == "Invoice 1234\nTotal: 499.00"


async def test_html_golden_extracts_title_and_visible_text() -> None:
    result = await _parse("article.html", "text/html")
    assert result.title == "Quarterly Review"
    assert result.text == "Budget\nNumbers attached."


async def test_markdown_golden_stays_plain() -> None:
    result = await _parse("readme.md", "text/markdown")
    assert result.text == "# README\n\nBody text"


async def test_plain_text_golden_is_stripped() -> None:
    result = await _parse("draft.txt", "text/plain")
    assert result.text == "hello world\nsecond line"


async def test_csv_json_xml_goldens_pass_through_plain() -> None:
    parser = _parser()
    assert (await parser.parse("sample.csv", mime_type="text/csv")).text == (
        "name,role\nAda,PM\nBob,Eng"
    )
    assert (
        await parser.parse("manifest.json", mime_type="application/json")
    ).text == '{"app": "ai-knowledge-companion", "version": 1}'
    assert (
        await parser.parse("feed.xml", mime_type="application/xml")
    ).text == '<?xml version="1.0"?><rss><channel><title>Feed</title></channel></rss>'


def test_pdf_golden_fixture_is_a_real_pdf() -> None:
    raw = (_FIXTURES / "sample.pdf").read_bytes()
    assert raw.startswith(b"%PDF")
    assert b"startxref" in raw and raw.rstrip().endswith(b"%%EOF")


async def test_pdf_is_not_a_document_for_the_parser() -> None:
    """PDFs ride the OCR seam, so the parser must reject application/pdf."""
    with pytest.raises(ProviderOutputError) as exc:
        await _parse("sample.pdf", "application/pdf")
    assert "unsupported document mime type" in str(exc.value)


async def test_ocr_placeholder_rejects_pdf_golden_structurally() -> None:
    """The OCR seam's Phase 1 stand-in fails with NOT_IMPLEMENTED for the
    golden PDF — pinning the contract the Phase 2 OCR adapter replaces."""
    with pytest.raises(JobFailedError) as exc:
        await PlaceholderOcrProvider().extract_text(
            "sample.pdf", mime_type="application/pdf"
        )
    assert exc.value.code == "NOT_IMPLEMENTED"
