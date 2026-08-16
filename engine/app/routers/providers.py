"""Provider credential endpoints (architecture §12, §5.3).

Provider keys are managed server-side, user-scoped. The API never echoes a
stored key back — `configured` is the only read signal.

- PUT    /api/v1/providers/{provider}/secret   upsert the user's key
- DELETE /api/v1/providers/{provider}/secret   remove it
- GET    /api/v1/providers/{provider}/secret   -> {"configured": bool}
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, Request

from app.auth import authenticate
from app.errors import InvalidRequestError
from app.models import Envelope, ProviderSecretRequest
from app.secrets import get_secret_store, normalize_provider

router = APIRouter(prefix="/api/v1", tags=["providers"])


async def _current_user(request: Request) -> str:
    return await authenticate(request)


def _validated_provider(provider: str) -> str:
    try:
        return normalize_provider(provider)
    except ValueError as exc:
        raise InvalidRequestError(str(exc)) from exc


@router.put("/providers/{provider}/secret", response_model_exclude_none=True)
async def set_provider_secret(
    provider: str,
    body: ProviderSecretRequest,
    user_id: str = Depends(_current_user),
) -> Envelope:
    provider = _validated_provider(provider)
    api_key = body.api_key.strip()
    if not api_key:
        raise InvalidRequestError("api_key must not be blank")
    get_secret_store().set(user_id, provider, api_key)
    return Envelope(data={"provider": provider, "configured": True})


@router.get("/providers/{provider}/secret", response_model_exclude_none=True)
async def get_provider_secret(
    provider: str,
    user_id: str = Depends(_current_user),
) -> Envelope:
    provider = _validated_provider(provider)
    configured = get_secret_store().get(user_id, provider) is not None
    return Envelope(data={"provider": provider, "configured": configured})


@router.delete("/providers/{provider}/secret", response_model_exclude_none=True)
async def delete_provider_secret(
    provider: str,
    user_id: str = Depends(_current_user),
) -> Envelope:
    provider = _validated_provider(provider)
    get_secret_store().delete(user_id, provider)
    return Envelope(data={"provider": provider, "configured": False})
