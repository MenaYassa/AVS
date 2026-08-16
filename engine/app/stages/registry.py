"""Stage factory: resolves ordered, configured stages for a job (§4.2).

Stages are independently replaceable: `build_stages` maps each pipeline stage
name to a single-responsibility implementation, resolves its prompt asset
(latest version) and its per-stage `StageConfig`, and fetches the configured
provider from the provider registry.
"""

from __future__ import annotations

from typing import Any

from app.prompts.registry import PromptRegistry
from app.providers.registry import get_llm
from app.stages.base import Stage
from app.stages.classification import ClassificationStage
from app.stages.cleanup import CleanupStage
from app.stages.context import StageConfig, TokenBudget
from app.stages.embedding import EmbeddingStage
from app.stages.entity_extraction import EntityExtractionStage
from app.stages.knowledge_extraction import KnowledgeExtractionStage
from app.stages.names import (
    PIPELINE_STAGES,
    STAGE_CLASSIFICATION,
    STAGE_CLEANUP,
    STAGE_EMBEDDING,
    STAGE_ENTITY_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_SEGMENTATION,
    STAGE_TAGS,
    STAGE_TASK_EXTRACTION,
    STAGE_VALIDATION,
)
from app.stages.segmentation import SegmentationStage
from app.stages.tags import TagsStage
from app.stages.task_extraction import TaskExtractionStage
from app.stages.validation import ValidationStage

_LLM_STAGES: dict[str, type[Stage]] = {
    STAGE_CLEANUP: CleanupStage,
    STAGE_SEGMENTATION: SegmentationStage,
    STAGE_CLASSIFICATION: ClassificationStage,
    STAGE_ENTITY_EXTRACTION: EntityExtractionStage,
    STAGE_TASK_EXTRACTION: TaskExtractionStage,
    STAGE_KNOWLEDGE_EXTRACTION: KnowledgeExtractionStage,
    STAGE_TAGS: TagsStage,
}


def stage_pipeline() -> list[str]:
    """Ordered stage names resolved from config (architecture §4.2)."""
    return list(PIPELINE_STAGES)


def build_stages(
    prompt_registry: PromptRegistry,
    options: dict[str, Any] | None,
    budget: TokenBudget,
    *,
    user_id: str | None = None,
) -> list[Stage]:
    ordered: list[Stage] = []
    for name in stage_pipeline():
        asset = prompt_registry.latest(name)
        if name == STAGE_VALIDATION:
            ordered.append(ValidationStage(asset=asset, budget=budget))
            continue
        if name == STAGE_EMBEDDING:
            ordered.append(EmbeddingStage())
            continue
        config = StageConfig.from_options(name, options, asset)
        stage_class = _LLM_STAGES[name]
        ordered.append(
            stage_class(
                asset=asset,
                config=config,
                provider=get_llm(
                    config.provider,
                    user_id=user_id,
                    base_url=config.base_url,
                    model=config.model,
                ),
                budget=budget,
            )
        )
    return ordered
