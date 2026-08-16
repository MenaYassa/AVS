"""Plugin adapter interface (architecture §4.11).

Outbound integrations attach behind a single adapter interface: OAuth2
credentials live in the server-side secret store, and `push` transforms the
command Draft (`draft.schema.json`) into the target's canonical payload —
structured JSON for issue trackers/docs, Markdown for messaging. Adapters are
pure HTTP transforms — no AI, no session state — so they are independently
replaceable.
"""

from __future__ import annotations

from typing import Any

import httpx
from pydantic import BaseModel, ConfigDict, Field

from app.errors import EngineError


class PluginNotConfiguredError(EngineError):
    http_status = 400
    code = "PLUGIN_NOT_CONFIGURED"


class PluginNotConnectedError(EngineError):
    http_status = 400
    code = "PLUGIN_NOT_CONNECTED"


class OAuthStateInvalidError(EngineError):
    http_status = 400
    code = "OAUTH_STATE_INVALID"


class InvalidDraftError(EngineError):
    http_status = 400
    code = "DRAFT_INVALID"


class PluginNotFoundError(EngineError):
    http_status = 404
    code = "PLUGIN_UNKNOWN"


class PluginAuthError(EngineError):
    http_status = 502
    code = "PLUGIN_AUTH_FAILED"


class PluginPushError(EngineError):
    http_status = 502
    code = "PLUGIN_PUSH_FAILED"


class PluginCredentials(BaseModel):
    """OAuth2 token pair stored server-side per user + plugin kind."""

    model_config = ConfigDict(extra="forbid")

    kind: str
    access_token: str = Field(min_length=1)
    refresh_token: str | None = None
    token_type: str = "Bearer"
    scope: str | None = None
    expires_at: str | None = None


class PushReceipt(BaseModel):
    """Outcome of a plugin push (architecture §4.11)."""

    model_config = ConfigDict(extra="forbid")

    kind: str
    ok: bool = True
    target_url: str | None = None
    external_id: str | None = None
    message: str | None = None


def _error_details(resp: httpx.Response) -> dict[str, Any]:
    try:
        return {"body": resp.json()}
    except Exception:  # noqa: BLE001
        return {"body": resp.text[:500]}


class Plugin:
    """Base class for OAuth2 plugin targets.

    Subclasses declare the provider's OAuth endpoints and implement
    `push` (draft → target payload → remote call). `exchange_token` and
    `refresh` return fresh `PluginCredentials`; the caller owns persisting
    them into the secret store.
    """

    kind = ""
    display_name = ""
    scopes: list[str] = []

    auth_base_url = ""
    token_url = ""

    def __init__(
        self,
        *,
        client: httpx.AsyncClient,
        client_id: str,
        client_secret: str,
    ) -> None:
        self.client = client
        self.client_id = client_id
        self.client_secret = client_secret

    @property
    def configured(self) -> bool:
        return bool(self.client_id and self.client_secret)

    def authorization_url(self, redirect_uri: str, state: str) -> str:
        raise NotImplementedError

    async def exchange_token(self, code: str, redirect_uri: str) -> PluginCredentials:
        raise NotImplementedError

    async def refresh(self, refresh_token: str) -> PluginCredentials:
        raise NotImplementedError

    async def push(
        self,
        credentials: PluginCredentials,
        draft: dict[str, Any],
        target: str | None = None,
    ) -> PushReceipt:
        raise NotImplementedError
