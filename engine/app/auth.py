"""Supabase JWT verification for the engine (architecture §6, §7.1).

The engine accepts the same access token the app uses against PostgREST.
`sub` becomes the `user_id` that scopes every job. When no Supabase project is
configured (local dev), an `X-User-Id` header identifies the caller.
"""

from __future__ import annotations

import time
from typing import Any

import httpx
import jwt
from fastapi import Request

from app.config import settings
from app.errors import UnauthorizedError


class SupabaseJWTVerifier:
    """Fetches and caches the Supabase JWKS and verifies access tokens."""

    def __init__(self, supabase_url: str, jwks_ttl_seconds: int = 300) -> None:
        self.jwks_url = f"{supabase_url}/auth/v1/.well-known/jwks.json"
        self.project_ref = supabase_url.split("//")[1].split(".")[0]
        self.jwks_ttl_seconds = jwks_ttl_seconds
        self._jwks: dict[str, Any] | None = None
        self._fetched_at = 0.0

    def _fetch_jwks(self) -> dict[str, Any]:
        if (
            self._jwks is not None
            and time.monotonic() - self._fetched_at < self.jwks_ttl_seconds
        ):
            return self._jwks
        with httpx.Client(timeout=10) as client:
            response = client.get(self.jwks_url)
            response.raise_for_status()
            self._jwks = response.json()
        self._fetched_at = time.monotonic()
        return self._jwks

    def verify(self, token: str) -> str:
        """Return the verified `user_id` (JWT `sub`) or raise UnauthorizedError."""
        try:
            jwks = self._fetch_jwks()
            key = jwt.PyJWKSet(jwks).get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                key,
                algorithms=["RS256"],
                audience=self.project_ref,
            )
        except Exception as exc:  # noqa: BLE001 - normalize all auth failures
            raise UnauthorizedError("Invalid or expired access token") from exc
        return str(claims["sub"])


_verifier: SupabaseJWTVerifier | None = None


def _get_verifier() -> SupabaseJWTVerifier:
    global _verifier
    if _verifier is None:
        _verifier = SupabaseJWTVerifier(settings.supabase_url)
    return _verifier


async def authenticate(request: Request) -> str:
    """Resolve the caller's user_id from the request.

    Production: `Authorization: Bearer <supabase-access-token>`.
    Dev (`SUPABASE_URL` unset): `X-User-Id` header, defaulting to `dev-user`.
    Service-to-service: `X-Engine-Service-Key` matching an ENGINE_SERVICE_KEYS entry.
    """
    service_key = request.headers.get("X-Engine-Service-Key")
    if service_key:
        if settings.service_api_keys and service_key in settings.service_api_keys:
            return "__service__"
        raise UnauthorizedError("Invalid service API key")

    authorization = request.headers.get("Authorization", "")
    if authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
        if settings.supabase_url:
            return _get_verifier().verify(token)
        # Dev mode: accept any bearer token and attribute it to its subject.
        try:
            return jwt.decode(token, options={"verify_signature": False})["sub"]
        except Exception:  # noqa: BLE001
            raise UnauthorizedError("Invalid bearer token") from None

    if settings.dev_mode:
        user_id = request.headers.get("X-User-Id")
        if user_id:
            return user_id
        raise UnauthorizedError("Missing Authorization header (dev: use X-User-Id)")

    raise UnauthorizedError("Missing Authorization header")
