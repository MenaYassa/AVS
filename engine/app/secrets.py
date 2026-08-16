"""Server-side provider credential store (architecture §12, §5.3).

Provider keys live only server-side (engine env/secret store) unless the user
configures a *custom* provider, where the key stays in device secure storage
and is used for that request only.

Resolution order for a provider key: user-configured secret (per user) first,
then the environment (`{PROVIDER}_API_KEY`, e.g. `OPENAI_API_KEY`).
"""

from __future__ import annotations

import os
import re
from typing import Any, Protocol

from app.config import settings

# Built-in providers may also resolve a key from the environment
# (e.g. OPENAI_API_KEY); user-set secrets take precedence.
_ENV_KEY_SUFFIX = "_API_KEY"
_PROVIDER_PATTERN = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")


def normalize_provider(provider: str) -> str:
    """Lowercase/strip and validate a provider name (e.g. `openai_whisper`)."""
    normalized = provider.strip().lower()
    if not _PROVIDER_PATTERN.match(normalized):
        raise ValueError(f"Invalid provider name: {provider!r}")
    return normalized


def env_key_for(provider: str) -> str:
    return f"{provider.upper()}{_ENV_KEY_SUFFIX}"


class SecretStore(Protocol):
    """Per-user provider credential store. Keys are never exposed wholesale."""

    def set(self, user_id: str, provider: str, key: str) -> None: ...
    def get(self, user_id: str, provider: str) -> str | None: ...
    def delete(self, user_id: str, provider: str) -> None: ...


class MemorySecretStore:
    """Hermetic per-user store (default + tests)."""

    def __init__(self) -> None:
        self._secrets: dict[tuple[str, str], str] = {}

    def set(self, user_id: str, provider: str, key: str) -> None:
        self._secrets[(user_id, provider)] = key

    def get(self, user_id: str, provider: str) -> str | None:
        return self._secrets.get((user_id, provider))

    def delete(self, user_id: str, provider: str) -> None:
        self._secrets.pop((user_id, provider), None)


class RedisSecretStore:
    """Redis-backed store (compose topology). One hash per user."""

    KEY_PREFIX = "engine:secret:"

    def __init__(self, redis_client: Any) -> None:
        self._r = redis_client

    @staticmethod
    def _key(user_id: str) -> str:
        return f"{RedisSecretStore.KEY_PREFIX}{user_id}"

    def set(self, user_id: str, provider: str, key: str) -> None:
        self._r.hset(self._key(user_id), provider, key)

    def get(self, user_id: str, provider: str) -> str | None:
        value = self._r.hget(self._key(user_id), provider)
        return value.decode() if isinstance(value, bytes) else value

    def delete(self, user_id: str, provider: str) -> None:
        self._r.hdel(self._key(user_id), provider)


_secret_store: SecretStore | None = None


def get_secret_store() -> SecretStore:
    global _secret_store
    if _secret_store is None:
        if settings.use_redis:
            import redis as redis_lib

            _secret_store = RedisSecretStore(redis_lib.from_url(settings.redis_url))
        else:
            _secret_store = MemorySecretStore()
    return _secret_store


def resolve_provider_key(user_id: str, provider: str) -> str | None:
    """User-configured key first, then the environment (built-in providers)."""
    provider = normalize_provider(provider)
    key = get_secret_store().get(user_id, provider)
    if key:
        return key
    return os.getenv(env_key_for(provider))
