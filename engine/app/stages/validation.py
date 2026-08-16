"""Validation stage: assemble + schema-check the canonical session (§4.2).

Deterministic (no LLM call): runs `assemble_canonical_session` and pushes the
result through the shared JSON Schema contract. Invalid assembly raises a
structured `VALIDATION_FAILED` error instead of emitting bad data.
"""

from __future__ import annotations

import json

from app.errors import JobFailedError
from app.schemas import validate_session
from app.stages.assembly import assemble_canonical_session
from app.stages.base import DeterministicStage
from app.stages.context import StageContext
from app.stages.names import STAGE_VALIDATION


class ValidationStage(DeterministicStage):
    name = STAGE_VALIDATION

    def build(self, ctx: StageContext) -> dict[str, object]:
        session = assemble_canonical_session(ctx)
        try:
            validate_session(session)
        except Exception as exc:  # noqa: BLE001
            raise JobFailedError(
                "Validated session failed the canonical schema",
                code="VALIDATION_FAILED",
                details={
                    "error": str(exc),
                    "session": json.loads(json.dumps(session, default=str)),
                },
            ) from exc
        return session
