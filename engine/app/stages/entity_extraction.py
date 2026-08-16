"""Entity extraction stage: named entities with aliases + confidence (§4.8).

Version 2 also extracts the relationships between entities so the pipeline
feeds edges into the knowledge graph (§4.8), not just nodes.
"""

from __future__ import annotations

from typing import Any

from app.stages.base import LLMStage, StageOutputError
from app.stages.context import StageContext
from app.stages.names import STAGE_CLEANUP, STAGE_ENTITY_EXTRACTION
from pydantic import BaseModel, Field

# Canonical entity types (architecture §4.8 — people, projects, organizations,
# ideas, tasks, decisions — plus the extraction-era product/tool/place/event/
# concept/date set). Mirrors `entity_type` in `session.schema.json`.
ENTITY_TYPES = (
    "person",
    "project",
    "organization",
    "idea",
    "task",
    "decision",
    "event",
    "product",
    "tool",
    "place",
    "concept",
    "date",
)

# Canonical relationship types (architecture §4.8). Mirrors `relationship_type`
# in `session.schema.json`.
RELATIONSHIP_TYPES = (
    "participates_in",
    "leads",
    "discusses",
    "depends_on",
    "assigned_to",
    "related_to",
)


class Entity(BaseModel):
    name: str = Field(min_length=1)
    type: str = Field(pattern="|".join(ENTITY_TYPES))
    aliases: list[str] = Field(default_factory=list)
    confidence: float = Field(ge=0.0, le=1.0)


class Relationship(BaseModel):
    source: str = Field(min_length=1)
    target: str = Field(min_length=1)
    type: str = Field(pattern="|".join(RELATIONSHIP_TYPES))
    confidence: float = Field(ge=0.0, le=1.0)


class EntityExtractionOutput(BaseModel):
    entities: list[Entity] = Field(default_factory=list)
    relationships: list[Relationship] = Field(default_factory=list)


class EntityExtractionStage(LLMStage):
    name = STAGE_ENTITY_EXTRACTION

    def render_user_prompt(self, ctx: StageContext) -> str:
        cleaned = ctx.require(STAGE_CLEANUP)["cleaned_text"]
        return self.asset.user_prompt_template.format(transcript=cleaned)

    def validate_output(self, parsed: dict[str, Any]) -> dict[str, Any]:
        try:
            return EntityExtractionOutput.model_validate(parsed).model_dump()
        except Exception as exc:  # noqa: BLE001
            raise StageOutputError(f"entity_extraction: {exc}") from exc
