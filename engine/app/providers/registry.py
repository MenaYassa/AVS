"""Pluggable provider registry (architecture §4.4).

Adapters register *factories* here; the orchestrator resolves providers by name
from `StageConfig`, threading the job's `user_id` through so provider keys
resolve per user (user-configured secret first, then env, §12). Registered
*instances* (P2-A placeholders, test fakes) short-circuit the factory path and
bypass key resolution.

Built-in adapters live in `app/providers/llm.py` and `app/providers/stt.py` and
are registered at import time via `register_*_factory`.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Any, Callable

from app.config import settings
from app.errors import JobFailedError
from app.providers.base import LLMProvider, Message
from app.secrets import resolve_provider_key

if TYPE_CHECKING:
    from app.inputs.base import (
        DocumentParserProvider,
        OcrProvider,
        TranscriptionProvider,
    )

LLMFactory = Callable[..., LLMProvider]
TranscriberFactory = Callable[..., "TranscriptionProvider"]
OcrFactory = Callable[..., "OcrProvider"]
ParserFactory = Callable[..., "DocumentParserProvider"]

_LLMS: dict[str, LLMProvider] = {}
_LLM_FACTORIES: dict[str, LLMFactory] = {}
_TRANSCRIBERS: dict[str, TranscriptionProvider] = {}
_TRANSCRIBER_FACTORIES: dict[str, TranscriberFactory] = {}
_OCRS: dict[str, OcrProvider] = {}
_OCR_FACTORIES: dict[str, OcrFactory] = {}
_PARSERS: dict[str, DocumentParserProvider] = {}
_PARSER_FACTORIES: dict[str, ParserFactory] = {}


def _ensure_placeholders() -> None:
    """Register the placeholder providers lazily (import order: inputs/voice
    imports this module, so a top-level import here would be circular)."""
    if "placeholder" not in _LLMS:
        _LLMS["placeholder"] = PlaceholderLLMProvider()
    if "placeholder" not in _TRANSCRIBERS:
        from app.inputs.voice import PlaceholderTranscriptionProvider

        _TRANSCRIBERS["placeholder"] = PlaceholderTranscriptionProvider()
    if "placeholder" not in _OCRS:
        from app.inputs.ocr import PlaceholderOcrProvider

        _OCRS["placeholder"] = PlaceholderOcrProvider()
    if "placeholder" not in _PARSERS:
        from app.inputs.parsers import PlaceholderDocumentParserProvider

        _PARSERS["placeholder"] = PlaceholderDocumentParserProvider()


def register_builtins() -> None:
    """Register the real adapters (P2-B). Imported by the worker entrypoints
    and by tests that exercise adapters end-to-end."""
    from app.providers.llm import AnthropicMessagesLLM, GeminiLLM, OpenAICompatibleLLM
    from app.providers.stt import (
        AssemblyAISTT,
        DeepgramSTT,
        OpenAIWhisperSTT,
    )

    def _openai_compatible(**kwargs: Any) -> LLMProvider:
        return OpenAICompatibleLLM(
            base_url=kwargs["base_url"],
            model=kwargs["model"],
            api_key=kwargs.get("api_key"),
            temperature=settings.default_temperature,
            client=kwargs.get("client"),
        )

    for provider in ("openai", "openrouter", "ollama", "lm_studio", "custom"):
        register_llm_factory(provider, _openai_compatible)

    register_llm_factory(
        "anthropic",
        lambda **kw: AnthropicMessagesLLM(
            base_url=kw["base_url"],
            model=kw["model"],
            api_key=kw.get("api_key"),
            temperature=settings.default_temperature,
            client=kw.get("client"),
        ),
    )
    register_llm_factory(
        "gemini",
        lambda **kw: GeminiLLM(
            base_url=kw["base_url"],
            model=kw["model"],
            api_key=kw.get("api_key"),
            temperature=settings.default_temperature,
            client=kw.get("client"),
        ),
    )

    from app.blobstore import get_blob_fetcher

    def _whisper(**kw: Any) -> TranscriptionProvider:
        return OpenAIWhisperSTT(
            base_url=kw["base_url"],
            model=kw["model"],
            api_key=kw.get("api_key"),
            blob_fetcher=kw.get("blob_fetcher") or get_blob_fetcher(),
            client=kw.get("client"),
        )

    def _deepgram(**kw: Any) -> TranscriptionProvider:
        return DeepgramSTT(
            base_url=kw["base_url"],
            model=kw["model"],
            api_key=kw.get("api_key"),
            blob_fetcher=kw.get("blob_fetcher") or get_blob_fetcher(),
            client=kw.get("client"),
        )

    def _assemblyai(**kw: Any) -> TranscriptionProvider:
        return AssemblyAISTT(
            base_url=kw["base_url"],
            model=kw["model"],
            api_key=kw.get("api_key"),
            blob_fetcher=kw.get("blob_fetcher") or get_blob_fetcher(),
            client=kw.get("client"),
        )

    register_transcriber_factory("openai_whisper", _whisper)
    register_transcriber_factory("deepgram", _deepgram)
    register_transcriber_factory("assemblyai", _assemblyai)

    def _stdlib_parser(**kw: Any) -> DocumentParserProvider:
        from app.inputs.parsers import StdlibDocumentParser

        return StdlibDocumentParser(
            blob_fetcher=kw.get("blob_fetcher") or get_blob_fetcher()
        )

    register_parser_factory("stdlib", _stdlib_parser)


class PlaceholderLLMProvider:
    """P2-A stand-in; replaced by OpenAI/Anthropic/Gemini/etc. adapters."""

    async def complete(
        self,
        messages: list[Message],
        *,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> str:
        raise JobFailedError(
            "LLM providers are not wired yet (Phase 2-B).",
            code="NOT_IMPLEMENTED",
            details={"model": model},
        )

    async def complete_structured(
        self,
        prompt: str,
        json_schema: str | dict[str, Any] | None,
        *,
        system_prompt: str | None = None,
        model: str | None = None,
        temperature: float | None = None,
        max_tokens: int | None = None,
    ) -> dict[str, Any]:
        raise JobFailedError(
            "LLM providers are not wired yet (Phase 2-B).",
            code="NOT_IMPLEMENTED",
            details={"model": model},
        )


def _default_llm_name() -> str:
    return settings.default_llm_provider or "placeholder"


def _default_stt_name() -> str:
    return settings.default_stt_provider or "placeholder"


def _default_ocr_name() -> str:
    return settings.default_ocr_provider or "placeholder"


def _default_parser_name() -> str:
    return settings.default_parser_provider or "stdlib"


def register_llm(name: str, provider: LLMProvider) -> None:
    _LLMS[name] = provider


def register_llm_factory(name: str, factory: LLMFactory) -> None:
    _LLM_FACTORIES[name] = factory


def register_transcriber(name: str, provider: TranscriptionProvider) -> None:
    _TRANSCRIBERS[name] = provider


def register_transcriber_factory(name: str, factory: TranscriberFactory) -> None:
    _TRANSCRIBER_FACTORIES[name] = factory


def register_ocr(name: str, provider: OcrProvider) -> None:
    _OCRS[name] = provider


def register_ocr_factory(name: str, factory: OcrFactory) -> None:
    _OCR_FACTORIES[name] = factory


def unregister_llm(name: str) -> None:
    _LLMS.pop(name, None)
    _LLM_FACTORIES.pop(name, None)


def unregister_transcriber(name: str) -> None:
    _TRANSCRIBERS.pop(name, None)
    _TRANSCRIBER_FACTORIES.pop(name, None)


def unregister_ocr(name: str) -> None:
    _OCRS.pop(name, None)
    _OCR_FACTORIES.pop(name, None)


def register_parser(name: str, provider: DocumentParserProvider) -> None:
    _PARSERS[name] = provider


def register_parser_factory(name: str, factory: ParserFactory) -> None:
    _PARSER_FACTORIES[name] = factory


def unregister_parser(name: str) -> None:
    _PARSERS.pop(name, None)
    _PARSER_FACTORIES.pop(name, None)


def _factory_kwargs(
    name: str,
    *,
    base_url: str | None,
    model: str | None,
    api_key: str | None,
    client: Any | None,
) -> dict[str, Any]:
    return {
        "base_url": base_url or settings.provider_base_urls.get(name) or "",
        "model": model or settings.provider_models.get(name) or "",
        "api_key": api_key,
        "client": client,
    }


def get_llm(
    name: str | None = None,
    *,
    user_id: str | None = None,
    base_url: str | None = None,
    model: str | None = None,
    client: Any | None = None,
) -> LLMProvider:
    _ensure_placeholders()
    key = name or _default_llm_name()
    provider = _LLMS.get(key)
    if provider is not None:
        return provider
    factory = _LLM_FACTORIES.get(key)
    if factory is None:
        raise JobFailedError(
            f"No LLM provider configured: {key!r}",
            code="NO_PROVIDER",
            details={"provider": key, "configured": sorted(_LLMS | _LLM_FACTORIES)},
        )
    kwargs = _factory_kwargs(
        key,
        base_url=base_url,
        model=model,
        api_key=resolve_provider_key(user_id or "", key),
        client=client,
    )
    return factory(**kwargs)


def get_transcriber(
    name: str | None = None,
    *,
    user_id: str | None = None,
    client: Any | None = None,
) -> TranscriptionProvider:
    _ensure_placeholders()
    key = name or _default_stt_name()
    provider = _TRANSCRIBERS.get(key)
    if provider is not None:
        return provider
    factory = _TRANSCRIBER_FACTORIES.get(key)
    if factory is None:
        raise JobFailedError(
            f"No transcription provider configured: {key!r}",
            code="NO_PROVIDER",
            details={
                "provider": key,
                "configured": sorted(_TRANSCRIBERS | _TRANSCRIBER_FACTORIES),
            },
        )
    kwargs = _factory_kwargs(
        key,
        base_url=None,
        model=None,
        api_key=resolve_provider_key(user_id or "", key),
        client=client,
    )
    return factory(**kwargs)


def get_ocr(
    name: str | None = None,
    *,
    user_id: str | None = None,
    client: Any | None = None,
) -> OcrProvider:
    _ensure_placeholders()
    key = name or _default_ocr_name()
    provider = _OCRS.get(key)
    if provider is not None:
        return provider
    factory = _OCR_FACTORIES.get(key)
    if factory is None:
        raise JobFailedError(
            f"No OCR provider configured: {key!r}",
            code="NO_PROVIDER",
            details={
                "provider": key,
                "configured": sorted(_OCRS | _OCR_FACTORIES),
            },
        )
    kwargs = _factory_kwargs(
        key,
        base_url=None,
        model=None,
        api_key=resolve_provider_key(user_id or "", key),
        client=client,
    )
    return factory(**kwargs)


def get_parser(
    name: str | None = None,
    *,
    user_id: str | None = None,
    client: Any | None = None,
) -> DocumentParserProvider:
    _ensure_placeholders()
    key = name or _default_parser_name()
    provider = _PARSERS.get(key)
    if provider is not None:
        return provider
    factory = _PARSER_FACTORIES.get(key)
    if factory is None:
        raise JobFailedError(
            f"No document parser configured: {key!r}",
            code="NO_PROVIDER",
            details={
                "provider": key,
                "configured": sorted(_PARSERS | _PARSER_FACTORIES),
            },
        )
    kwargs = _factory_kwargs(
        key,
        base_url=None,
        model=None,
        api_key=resolve_provider_key(user_id or "", key),
        client=client,
    )
    return factory(**kwargs)


register_builtins()
