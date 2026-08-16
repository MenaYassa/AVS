"""Runtime provider configuration regression tests."""

from __future__ import annotations

from app.config import Settings


def _fresh_settings() -> Settings:
    Settings.cache_clear()
    return Settings()


def test_openai_whisper_base_url_and_runtime_defaults(monkeypatch) -> None:
    monkeypatch.setenv("ENGINE_DEFAULT_STT", "openai_whisper")
    monkeypatch.setenv("ENGINE_DEFAULT_LLM", "openai")
    monkeypatch.setenv("ENGINE_DEFAULT_LLM_MODEL", "gpt-4o-mini")
    monkeypatch.setenv("OPENAI_WHISPER_MODEL", "whisper-1")

    configured = _fresh_settings()
    assert configured.default_stt_provider == "openai_whisper"
    assert configured.default_llm_provider == "openai"
    assert configured.default_llm_model == "gpt-4o-mini"
    assert configured.provider_base_urls["openai_whisper"] == (
        "https://api.openai.com/v1"
    )
    assert configured.provider_models["openai_whisper"] == "whisper-1"

    # Do not leak this test's cached environment-derived Settings instance into
    # later tests, which import the module-level runtime settings singleton.
    Settings.cache_clear()
