"""Ops endpoints (architecture §7.1)."""

from __future__ import annotations

from fastapi import APIRouter

from app.config import settings

router = APIRouter(tags=["ops"])


@router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok", "service": settings.engine_name}


@router.get("/readyz")
async def readyz() -> dict[str, str]:
    """Readiness reflects dependency availability (Redis when configured)."""
    if settings.use_redis:
        try:
            import redis

            redis.from_url(settings.redis_url).ping()
        except Exception:  # noqa: BLE001
            from fastapi import HTTPException

            raise HTTPException(status_code=503, detail="redis unreachable")
    return {"status": "ready", "service": settings.engine_name}


@router.get("/metrics")
async def metrics() -> dict[str, object]:
    """Phase 1: minimal counters; Prometheus exposition lands in Phase 2."""
    return {
        "service": settings.engine_name,
        "version": settings.version,
        "note": "full Prometheus metrics in Phase 2",
    }
