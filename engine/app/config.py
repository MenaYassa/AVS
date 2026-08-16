"""Environment-driven engine configuration."""

from __future__ import annotations

import os
from functools import lru_cache


@lru_cache
class Settings:
    """Engine settings. Every value is overridable via environment variables."""

    def __init__(self) -> None:  # noqa: PLR0912
        self.engine_name = os.getenv("ENGINE_NAME", "ai-knowledge-engine")
        self.version = os.getenv("ENGINE_VERSION", "0.1.0")

        # Supabase: when set, the engine verifies JWTs and derives user_id from
        # `sub`. When unset (local dev), `X-User-Id` is accepted.
        self.supabase_url = os.getenv("SUPABASE_URL", "").rstrip("/")

        # Postgres connection for pgvector semantic search (§5.4, §6.1). When
        # unset, semantic search returns embeddings but no cloud results.
        self.database_url = os.getenv("ENGINE_DATABASE_URL", "")

        # Job persistence: "memory" (default, hermetic) or "redis".
        self.job_store = os.getenv("ENGINE_JOB_STORE", "memory")
        self.redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
        self.redis_job_ttl = int(os.getenv("ENGINE_JOB_TTL", str(60 * 60 * 24 * 7)))

        # Queue
        self.queue_name = os.getenv("ENGINE_QUEUE", "jobs")
        self.worker_poll_seconds = float(os.getenv("ENGINE_WORKER_POLL", "1"))

        # Secrets (service-to-service path for Edge Functions, §7.1)
        self.service_api_keys = {
            key for key in os.getenv("ENGINE_SERVICE_KEYS", "").split(",") if key
        }

        # AI providers (architecture §4.4). Empty defaults resolve to the
        # placeholder providers until adapters are configured (Phase 2-B).
        self.default_llm_provider = os.getenv("ENGINE_DEFAULT_LLM", "")
        self.default_llm_model = os.getenv("ENGINE_DEFAULT_LLM_MODEL", "")
        self.default_stt_provider = os.getenv("ENGINE_DEFAULT_STT", "")
        self.default_ocr_provider = os.getenv("ENGINE_DEFAULT_OCR", "")
        self.default_parser_provider = os.getenv("ENGINE_DEFAULT_PARSER", "")
        self.default_temperature = float(os.getenv("ENGINE_DEFAULT_TEMPERATURE", "0.2"))

        # Provider base URLs (built-in adapters, §4.4 custom providers).
        self.provider_base_urls: dict[str, str] = {
            "openai": os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1"),
            "openai_whisper": os.getenv(
                "OPENAI_WHISPER_BASE_URL", "https://api.openai.com/v1"
            ),
            "openrouter": os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"),
            "ollama": os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/v1"),
            "lm_studio": os.getenv("LMSTUDIO_BASE_URL", "http://localhost:1234/v1"),
            "anthropic": os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com"),
            "gemini": os.getenv(
                "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com"
            ),
            "deepgram": os.getenv("DEEPGRAM_BASE_URL", "https://api.deepgram.com"),
            "assemblyai": os.getenv(
                "ASSEMBLYAI_BASE_URL", "https://api.assemblyai.com"
            ),
        }

        # Default models per built-in provider; overridable via {PROVIDER}_MODEL.
        self.provider_models: dict[str, str] = {
            "openai": os.getenv("OPENAI_MODEL", "gpt-4o-mini"),
            "openrouter": os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini"),
            "ollama": os.getenv("OLLAMA_MODEL", "llama3.2"),
            "lm_studio": os.getenv("LMSTUDIO_MODEL", "local-model"),
            "anthropic": os.getenv("ANTHROPIC_MODEL", "claude-3-5-haiku-latest"),
            "gemini": os.getenv("GEMINI_MODEL", "gemini-1.5-flash"),
            "openai_whisper": os.getenv("OPENAI_WHISPER_MODEL", "whisper-1"),
            "deepgram": os.getenv("DEEPGRAM_MODEL", "nova-2"),
        }

        # Blob store: where STT adapters fetch audio blobs from.
        # "local" -> ENGINE_BLOB_ROOT directory; "supabase" -> Storage download
        # via SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY.
        self.blob_store = os.getenv("ENGINE_BLOB_STORE", "local")
        self.blob_root = os.getenv("ENGINE_BLOB_ROOT", ".")
        self.supabase_service_role_key = os.getenv("SUPABASE_SERVICE_ROLE_KEY", "")

        # Token budgets (§2.1: token budget handling).
        self.max_input_tokens = int(os.getenv("ENGINE_MAX_INPUT_TOKENS", "32000"))
        self.max_output_tokens = int(os.getenv("ENGINE_MAX_OUTPUT_TOKENS", "8192"))

        # Plugin OAuth2 app credentials (architecture §4.11). Per plugin kind:
        # `client_id` / `client_secret` from `{KIND}_CLIENT_ID` /
        # `{KIND}_CLIENT_SECRET`. Empty until the operator registers an app.
        self.plugin_oauth: dict[str, dict[str, str]] = {
            "notion": {
                "client_id": os.getenv("NOTION_CLIENT_ID", ""),
                "client_secret": os.getenv("NOTION_CLIENT_SECRET", ""),
            },
            "slack": {
                "client_id": os.getenv("SLACK_CLIENT_ID", ""),
                "client_secret": os.getenv("SLACK_CLIENT_SECRET", ""),
            },
        }

    @property
    def use_redis(self) -> bool:
        return self.job_store == "redis"

    @property
    def dev_mode(self) -> bool:
        return not self.supabase_url


settings = Settings()
