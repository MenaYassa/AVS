"""Adapter golden-fixture tests (architecture §10.1).

Each case replays a recorded provider-native response through `httpx.MockTransport`
and asserts the adapter's canonical output. No network in CI.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Callable

import httpx
import pytest
from app.inputs.base import TranscriptionResult
from app.providers.base import Message, ProviderOutputError
from app.providers.llm import (
    AnthropicMessagesLLM,
    GeminiLLM,
    OpenAICompatibleLLM,
    extract_json,
)
from app.providers.stt import AssemblyAISTT, DeepgramSTT, OpenAIWhisperSTT

FIXTURES = Path(__file__).parent / "fixtures" / "providers"


def _load(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text())


class MemoryBlobFetcher:
    def __init__(self, data: bytes) -> None:
        self._data = data

    async def fetch(self, blob_ref: str) -> bytes:
        return self._data


def _transport(fn: Callable[[httpx.Request], httpx.Response]) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(fn))


def _messages(*texts: str) -> list[Message]:
    return [Message(role="user", content=t) for t in texts]


def _system_text() -> Message:
    return Message(role="system", content="You are helpful.")


class TestExtractJson:
    def test_fenced_json(self) -> None:
        assert extract_json("```json\n{\"a\": 1}\n```") == {"a": 1}

    def test_prose_with_json(self) -> None:
        text = 'Sure! Here: {"x": {"nested": [1, 2]}} done'
        assert extract_json(text) == {"x": {"nested": [1, 2]}}

    def test_string_with_braces_ignored(self) -> None:
        text = '{"a": "brace { inside string }"}'
        assert extract_json(text) == {"a": "brace { inside string }"}

    def test_no_json_raises(self) -> None:
        with pytest.raises(ProviderOutputError):
            extract_json("no json here")


class TestOpenAICompatibleLLM:
    @pytest.mark.asyncio
    async def test_complete_golden(self) -> None:
        fixture = _load("openai_chat_completion.json")

        def handler(request: httpx.Request) -> httpx.Response:
            body = json.loads(request.content)
            assert body["messages"][0]["role"] == "user"
            assert request.headers["authorization"] == "Bearer sk-test"
            return httpx.Response(200, json=fixture)

        llm = OpenAICompatibleLLM(
            base_url="https://api.openai.com/v1",
            model="gpt-4o-mini",
            api_key="sk-test",
            client=_transport(handler),
        )
        out = await llm.complete(_messages("hi"))
        assert out == "The user asked a question."

    @pytest.mark.asyncio
    async def test_complete_structured_golden(self) -> None:
        fixture = _load("openai_chat_structured.json")
        sent: dict[str, Any] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            sent.update(json.loads(request.content))
            return httpx.Response(200, json=fixture)

        llm = OpenAICompatibleLLM(
            base_url="https://api.openai.com/v1",
            model="gpt-4o-mini",
            client=_transport(handler),
        )
        out = await llm.complete_structured(
            "Extract", "dummy-schema", system_prompt="Be concise"
        )
        assert out == {"title": "Meeting notes", "confidence": 0.97}
        assert sent["response_format"] == {"type": "json_object"}
        assert sent["messages"][0]["role"] == "system"

    @pytest.mark.asyncio
    async def test_structured_without_schema_sends_no_response_format(self) -> None:
        fixture = _load("openai_chat_structured.json")

        def handler(request: httpx.Request) -> httpx.Response:
            assert "response_format" not in json.loads(request.content)
            return httpx.Response(200, json=fixture)

        llm = OpenAICompatibleLLM(
            base_url="https://api.openai.com/v1",
            model="gpt-4o-mini",
            client=_transport(handler),
        )
        await llm.complete_structured("Extract", None)

    @pytest.mark.asyncio
    async def test_malformed_completion_raises(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, json={"choices": []})

        llm = OpenAICompatibleLLM(
            base_url="https://api.openai.com/v1",
            model="gpt-4o-mini",
            client=_transport(handler),
        )
        with pytest.raises(ProviderOutputError):
            await llm.complete(_messages("hi"))


class TestAnthropicMessagesLLM:
    @pytest.mark.asyncio
    async def test_complete_golden(self) -> None:
        fixture = _load("anthropic_messages.json")

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["x-api-key"] == "ant-test"
            assert request.headers["anthropic-version"] == "2023-06-01"
            body = json.loads(request.content)
            assert body["system"] == "You are helpful."
            return httpx.Response(200, json=fixture)

        llm = AnthropicMessagesLLM(
            base_url="https://api.anthropic.com",
            model="claude-3-5-sonnet-20241022",
            api_key="ant-test",
            client=_transport(handler),
        )
        out = await llm.complete([_system_text(), _messages("hi")[0]])
        assert out == "Here is the summary you asked for."

    @pytest.mark.asyncio
    async def test_complete_structured_golden_extracts_from_prose(self) -> None:
        fixture = _load("anthropic_messages_structured.json")

        def handler(request: httpx.Request) -> httpx.Response:
            body = json.loads(request.content)
            assert "single JSON object" in body["messages"][0]["content"]
            return httpx.Response(200, json=fixture)

        llm = AnthropicMessagesLLM(
            base_url="https://api.anthropic.com",
            model="claude-3-5-sonnet-20241022",
            api_key="ant-test",
            client=_transport(handler),
        )
        out = await llm.complete_structured("Extract", "dummy-schema")
        assert out["topics"][0]["title"] == "Budget"
        assert out["confidence"] == 0.88

    @pytest.mark.asyncio
    async def test_requires_api_key(self) -> None:
        llm = AnthropicMessagesLLM(
            base_url="https://api.anthropic.com",
            model="claude-3-5-sonnet-20241022",
            api_key=None,
        )
        with pytest.raises(ProviderOutputError):
            await llm.complete(_messages("hi"))


class TestGeminiLLM:
    @pytest.mark.asyncio
    async def test_complete_golden(self) -> None:
        fixture = _load("gemini_generate.json")

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["x-goog-api-key"] == "gem-test"
            assert request.url.path.endswith(":generateContent")
            body = json.loads(request.content)
            assert body["systemInstruction"]["parts"][0]["text"] == "Be terse."
            return httpx.Response(200, json=fixture)

        llm = GeminiLLM(
            base_url="https://generativelanguage.googleapis.com",
            model="gemini-1.5-pro",
            api_key="gem-test",
            client=_transport(handler),
        )
        out = await llm.complete(
            [Message(role="system", content="Be terse."), _messages("hi")[0]]
        )
        assert out == "A concise answer from Gemini."

    @pytest.mark.asyncio
    async def test_complete_structured_golden(self) -> None:
        fixture = _load("gemini_generate_structured.json")

        def handler(request: httpx.Request) -> httpx.Response:
            body = json.loads(request.content)
            assert body["generationConfig"]["responseMimeType"] == "application/json"
            return httpx.Response(200, json=fixture)

        llm = GeminiLLM(
            base_url="https://generativelanguage.googleapis.com",
            model="gemini-1.5-pro",
            api_key="gem-test",
            client=_transport(handler),
        )
        out = await llm.complete_structured("Extract", "dummy-schema")
        assert out["entities"] == [{"name": "Acme", "type": "company"}]
        assert out["confidence"] == 0.82


class TestOpenAIWhisperSTT:
    @pytest.mark.asyncio
    async def test_transcribe_golden(self) -> None:
        fixture = _load("whisper_transcription.json")
        audio = b"fake-wav-bytes"

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["authorization"] == "Bearer sk-whisper"
            assert b"fake-wav-bytes" in request.content
            return httpx.Response(200, json=fixture)

        stt = OpenAIWhisperSTT(
            base_url="https://api.openai.com/v1",
            model="whisper-1",
            api_key="sk-whisper",
            blob_fetcher=MemoryBlobFetcher(audio),
            client=_transport(handler),
        )
        result = await stt.transcribe("bucket/audio.webm", language="en")
        assert result == TranscriptionResult(
            text="Good morning, team. Let us review the roadmap.",
            language="en",
        )

    @pytest.mark.asyncio
    async def test_empty_transcript_raises(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, json={"text": ""})

        stt = OpenAIWhisperSTT(
            base_url="https://api.openai.com/v1",
            model="whisper-1",
            api_key="sk-whisper",
            blob_fetcher=MemoryBlobFetcher(b"audio"),
            client=_transport(handler),
        )
        with pytest.raises(ProviderOutputError):
            await stt.transcribe("bucket/audio.webm")


class TestDeepgramSTT:
    @pytest.mark.asyncio
    async def test_transcribe_golden(self) -> None:
        fixture = _load("deepgram_listen.json")

        def handler(request: httpx.Request) -> httpx.Response:
            assert request.headers["authorization"] == "Token dg-test"
            assert request.url.params["model"] == "nova-2"
            assert request.url.params["language"] == "en"
            return httpx.Response(200, json=fixture)

        stt = DeepgramSTT(
            base_url="https://api.deepgram.com",
            model="nova-2",
            api_key="dg-test",
            blob_fetcher=MemoryBlobFetcher(b"audio"),
            client=_transport(handler),
        )
        result = await stt.transcribe("bucket/audio.webm", language="en")
        assert result.text == "We need to finalize the budget by Friday."
        assert result.confidence == 0.97
        assert result.language == "en"


class TestAssemblyAISTT:
    @pytest.mark.asyncio
    async def test_transcribe_golden_uploads_then_polls(self) -> None:
        upload = _load("assemblyai_upload.json")
        submit = _load("assemblyai_submit.json")
        completed = _load("assemblyai_transcript_completed.json")
        transcript_id = "abcd1234-efgh-5678-ijkl-9012mnopqrst"
        calls: list[str] = []

        def handler(request: httpx.Request) -> httpx.Response:
            calls.append(f"{request.method} {request.url.path}")
            assert request.headers["authorization"] == "Bearer aa-test"
            if request.method == "POST" and request.url.path == "/v2/upload":
                assert request.content == b"fake-audio"
                return httpx.Response(200, json=upload)
            if request.method == "POST" and request.url.path == "/v2/transcript":
                body = json.loads(request.content)
                assert body["audio_url"] == upload["audio_url"]
                assert body["speech_model"] == "best"
                return httpx.Response(200, json=submit)
            transcript_path = f"/v2/transcript/{transcript_id}"
            if request.method == "GET" and request.url.path == transcript_path:
                return httpx.Response(200, json=completed)
            return httpx.Response(404, json={"error": "unexpected"})

        stt = AssemblyAISTT(
            base_url="https://api.assemblyai.com",
            model="best",
            api_key="aa-test",
            blob_fetcher=MemoryBlobFetcher(b"fake-audio"),
            client=_transport(handler),
            poll_interval=0.0,
        )
        result = await stt.transcribe("bucket/audio.webm", language="en")
        assert result.text == "The quarterly review is scheduled for next Monday."
        assert result.confidence == 0.95
        assert result.language == "en"
        assert calls == [
            "POST /v2/upload",
            "POST /v2/transcript",
            f"GET /v2/transcript/{transcript_id}",
        ]

    @pytest.mark.asyncio
    async def test_poll_returns_completed_when_not_first_try(self) -> None:
        submit = _load("assemblyai_submit.json")
        completed = _load("assemblyai_transcript_completed.json")
        transcript_id = submit["id"]
        poll_count = {"n": 0}

        def handler(request: httpx.Request) -> httpx.Response:
            if request.method == "POST" and request.url.path == "/v2/upload":
                return httpx.Response(200, json=_load("assemblyai_upload.json"))
            if request.method == "POST" and request.url.path == "/v2/transcript":
                return httpx.Response(200, json=submit)
            poll_count["n"] += 1
            pending = _load("assemblyai_transcript_processing.json")
            body = completed if poll_count["n"] >= 2 else pending
            return httpx.Response(200, json=body)

        stt = AssemblyAISTT(
            base_url="https://api.assemblyai.com",
            model="best",
            api_key="aa-test",
            blob_fetcher=MemoryBlobFetcher(b"fake-audio"),
            client=_transport(handler),
            poll_interval=0.0,
        )
        result = await stt.transcribe(f"bucket/audio.webm?t={transcript_id}")
        assert result.text == "The quarterly review is scheduled for next Monday."
        assert poll_count["n"] == 2

    @pytest.mark.asyncio
    async def test_transcript_error_raises(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            if request.method == "GET":
                return httpx.Response(
                    200,
                    json={"id": "x", "status": "error", "error": "model exploded"},
                )
            if request.method == "POST" and request.url.path == "/v2/upload":
                return httpx.Response(200, json=_load("assemblyai_upload.json"))
            return httpx.Response(200, json=_load("assemblyai_submit.json"))

        stt = AssemblyAISTT(
            base_url="https://api.assemblyai.com",
            model="best",
            api_key="aa-test",
            blob_fetcher=MemoryBlobFetcher(b"fake-audio"),
            client=_transport(handler),
            poll_interval=0.0,
        )
        with pytest.raises(ProviderOutputError, match="model exploded"):
            await stt.transcribe("bucket/audio.webm")
