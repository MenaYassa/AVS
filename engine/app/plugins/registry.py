"""Plugin registry + server-side credential store (architecture §4.11).

Plugins register *factories* here; the router resolves a plugin by kind on
each request. Credentials are OAuth2 token pairs held in the server-side
secret store (per user + plugin kind), and pending OAuth state rides in the
same store under a distinct key so token exchange can validate `state`.
"""

from __future__ import annotations

import json
from typing import Any, Callable

import httpx

from app.config import settings
from app.plugins.base import (
    Plugin,
    PluginCredentials,
    PluginNotFoundError,
)
from app.secrets import get_secret_store

PluginFactory = Callable[[], Plugin]

_CREDENTIAL_PREFIX = "plugin:"
_STATE_PREFIX = "plugin_state:"

_REGISTRY: dict[str, PluginFactory] = {}


def _default_http_client() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=10.0))


_http_client_factory: Callable[[], httpx.AsyncClient] = _default_http_client


def set_http_client_factory(factory: Callable[[], httpx.AsyncClient]) -> None:
    """Test hook: inject a client (e.g. `httpx.AsyncClient(transport=...)`)."""
    global _http_client_factory
    _http_client_factory = factory


def get_http_client() -> httpx.AsyncClient:
    return _http_client_factory()


def register_plugin(kind: str, factory: PluginFactory) -> None:
    _REGISTRY[kind] = factory


def unregister_plugin(kind: str) -> None:
    _REGISTRY.pop(kind, None)


def plugin_kinds() -> list[str]:
    return sorted(_REGISTRY)


def get_plugin(kind: str) -> Plugin:
    factory = _REGISTRY.get(kind)
    if factory is None:
        raise PluginNotFoundError(
            f"Unknown plugin target: {kind!r}",
            details={"known": plugin_kinds()},
        )
    return factory()


def plugin_client_config(kind: str) -> dict[str, str]:
    """OAuth2 app credentials for a plugin (from settings, empty when unset)."""
    return settings.plugin_oauth.get(kind, {})


def register_builtins() -> None:
    from app.plugins.targets import NotionPlugin, SlackPlugin

    def _notion() -> Plugin:
        return NotionPlugin(client=get_http_client(), **plugin_client_config("notion"))

    def _slack() -> Plugin:
        return SlackPlugin(client=get_http_client(), **plugin_client_config("slack"))

    register_plugin("notion", _notion)
    register_plugin("slack", _slack)


def _credential_key(kind: str) -> str:
    return f"{_CREDENTIAL_PREFIX}{kind}"


def _state_key(kind: str) -> str:
    return f"{_STATE_PREFIX}{kind}"


def save_credentials(user_id: str, credentials: PluginCredentials) -> None:
    get_secret_store().set(
        user_id,
        _credential_key(credentials.kind),
        json.dumps(credentials.model_dump(mode="json")),
    )


def load_credentials(user_id: str, kind: str) -> PluginCredentials | None:
    raw = get_secret_store().get(user_id, _credential_key(kind))
    if not raw:
        return None
    try:
        return PluginCredentials.model_validate(json.loads(raw))
    except Exception:  # noqa: BLE001
        return None


def delete_credentials(user_id: str, kind: str) -> None:
    get_secret_store().delete(user_id, _credential_key(kind))


def is_connected(user_id: str, kind: str) -> bool:
    return load_credentials(user_id, kind) is not None


def save_pending_state(user_id: str, kind: str, state: str) -> None:
    get_secret_store().set(user_id, _state_key(kind), state)


def pop_pending_state(user_id: str, kind: str) -> str | None:
    store = get_secret_store()
    state = store.get(user_id, _state_key(kind))
    if state is not None:
        store.delete(user_id, _state_key(kind))
    return state


def list_plugin_status(user_id: str) -> list[dict[str, Any]]:
    """`[{kind, display_name, connected}]` for every registered plugin."""
    status: list[dict[str, Any]] = []
    for kind in plugin_kinds():
        plugin = get_plugin(kind)
        status.append(
            {
                "kind": plugin.kind,
                "display_name": plugin.display_name,
                "connected": is_connected(user_id, kind),
                "configured": plugin.configured,
            }
        )
    return status


register_builtins()
