"""AI Knowledge Engine — FastAPI application (architecture §4, §7.1)."""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.config import settings
from app.errors import EngineError
from app.routers import health, insights, jobs, plugins, providers, search

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

app = FastAPI(
    title="AI Knowledge Engine",
    version=settings.version,
    description="Orchestrated AI pipeline behind the AI Knowledge Companion.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health.router)
app.include_router(jobs.router)
app.include_router(insights.router)
app.include_router(plugins.router)
app.include_router(providers.router)
app.include_router(search.router)


@app.exception_handler(EngineError)
async def engine_error_handler(request: Request, exc: EngineError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.http_status,
        content=exc.to_envelope(),
    )


@app.get("/")
async def root() -> dict[str, str]:
    return {
        "service": settings.engine_name,
        "version": settings.version,
        "docs": "/docs",
    }
