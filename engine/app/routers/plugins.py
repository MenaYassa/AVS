"""Plugin endpoints (architecture §4.11, §7.1).

- `GET /api/v1/plugins` — list targets with connection status.
- `GET /api/v1/plugins/{kind}/auth-url` — start OAuth2 (returns `{url, state}`).
- `POST /api/v1/plugins/{kind}/token` — exchange the auth code (state-checked),
  persist the token pair server-side.
- `POST /api/v1/plugins/{kind}/push` — push a command Draft to the target.
- `DELETE /api/v1/plugins/{kind}/credentials` — disconnect.

Credentials never leave the server: the app triggers auth and push only.
"""

from __future__ import annotations

from uuid import uuid4

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, ConfigDict, Field

from app.auth import authenticate
from app.models import Envelope
from app.plugins.base import (
    InvalidDraftError,
    OAuthStateInvalidError,
    PluginNotConfiguredError,
    PluginNotConnectedError,
)
from app.plugins.registry import (
    delete_credentials,
    get_plugin,
    list_plugin_status,
    load_credentials,
    pop_pending_state,
    save_credentials,
    save_pending_state,
)
from app.schemas import plugin_schema, validate_against_schema

router = APIRouter(prefix="/api/v1", tags=["plugins"])


async def _current_user(request: Request) -> str:
    return await authenticate(request)


class TokenExchangeRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    code: str = Field(min_length=1)
    state: str = Field(min_length=1)
    redirect_uri: str = Field(min_length=1)


class PushRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    draft: dict[str, object]
    target: str | None = None


def _validate_draft_shape(draft: dict[str, object]) -> None:
    schema = plugin_schema()["definitions"]["push_request"]
    try:
        validate_against_schema({"draft": draft, "target": None}, schema)
    except Exception as exc:  # noqa: BLE001
        raise InvalidDraftError(str(exc)) from exc


@router.get("/plugins", response_model_exclude_none=True)
async def list_plugins(
    user_id: str = Depends(_current_user),
) -> Envelope:
    return Envelope(data={"plugins": list_plugin_status(user_id)})


@router.get("/plugins/{kind}/auth-url", response_model_exclude_none=True)
async def plugin_auth_url(
    kind: str,
    redirect_uri: str,
    user_id: str = Depends(_current_user),
) -> Envelope:
    plugin = get_plugin(kind)
    if not plugin.configured:
        raise PluginNotConfiguredError(
            f"Plugin '{kind}' is not configured on this engine",
            details={"kind": kind},
        )
    state = str(uuid4())
    save_pending_state(user_id, kind, state)
    return Envelope(
        data={
            "kind": kind,
            "display_name": plugin.display_name,
            "url": plugin.authorization_url(redirect_uri, state),
            "state": state,
        }
    )


@router.post("/plugins/{kind}/token", response_model_exclude_none=True)
async def plugin_token_exchange(
    kind: str,
    body: TokenExchangeRequest,
    user_id: str = Depends(_current_user),
) -> Envelope:
    plugin = get_plugin(kind)
    expected = pop_pending_state(user_id, kind)
    if expected is None or expected != body.state:
        raise OAuthStateInvalidError(
            "OAuth state mismatch or missing authorization",
            details={"kind": kind},
        )
    credentials = await plugin.exchange_token(body.code, body.redirect_uri)
    save_credentials(user_id, credentials)
    return Envelope(
        data={
            "kind": kind,
            "display_name": plugin.display_name,
            "connected": True,
        }
    )


@router.post("/plugins/{kind}/push", response_model_exclude_none=True)
async def plugin_push(
    kind: str,
    body: PushRequest,
    user_id: str = Depends(_current_user),
) -> Envelope:
    _validate_draft_shape(body.draft)
    plugin = get_plugin(kind)
    credentials = load_credentials(user_id, kind)
    if credentials is None:
        raise PluginNotConnectedError(
            f"Plugin '{kind}' is not connected",
            details={"kind": kind},
        )
    receipt = await plugin.push(credentials, body.draft, body.target)
    return Envelope(data=receipt.model_dump(mode="json"))


@router.delete("/plugins/{kind}/credentials", response_model_exclude_none=True)
async def plugin_disconnect(
    kind: str,
    user_id: str = Depends(_current_user),
) -> Envelope:
    delete_credentials(user_id, kind)
    return Envelope(data={"kind": kind, "connected": False})
