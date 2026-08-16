"""Structured errors matching the engine envelope (architecture §7.1)."""

from __future__ import annotations

from typing import Any


class EngineError(Exception):
    """Base class for engine errors that serialize to the error envelope."""

    http_status = 500
    code = "INTERNAL_ERROR"

    def __init__(self, message: str, details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.details = details

    def to_envelope(self) -> dict[str, Any]:
        error: dict[str, Any] = {"code": self.code, "message": self.message}
        if self.details is not None:
            error["details"] = self.details
        return {"status": "error", "error": error}


class JobNotFoundError(EngineError):
    http_status = 404
    code = "JOB_NOT_FOUND"


class JobAccessDeniedError(EngineError):
    http_status = 403
    code = "JOB_ACCESS_DENIED"


class InvalidRequestError(EngineError):
    http_status = 400
    code = "INVALID_REQUEST"


class JobCanceledError(EngineError):
    http_status = 409
    code = "JOB_CANCELLED"


class UnauthorizedError(EngineError):
    http_status = 401
    code = "UNAUTHORIZED"


class JobFailedError(EngineError):
    """Raised by the worker; carries the structured failure stored on the job."""

    def __init__(
        self,
        message: str,
        code: str = "JOB_FAILED",
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, details)
        self.code = code
