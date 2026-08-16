"""Pipeline stage names (architecture §4.2). Shared by the orchestrator, the
stage registry, and the prompt registry (asset keys)."""

STAGE_CLEANUP = "cleanup"
STAGE_SEGMENTATION = "segmentation"
STAGE_CLASSIFICATION = "classification"
STAGE_ENTITY_EXTRACTION = "entity_extraction"
STAGE_TASK_EXTRACTION = "task_extraction"
STAGE_KNOWLEDGE_EXTRACTION = "knowledge_extraction"
STAGE_TAGS = "tags"
STAGE_VALIDATION = "validation"
STAGE_EMBEDDING = "embedding"

PIPELINE_STAGES: tuple[str, ...] = (
    STAGE_CLEANUP,
    STAGE_SEGMENTATION,
    STAGE_CLASSIFICATION,
    STAGE_ENTITY_EXTRACTION,
    STAGE_TASK_EXTRACTION,
    STAGE_KNOWLEDGE_EXTRACTION,
    STAGE_TAGS,
    STAGE_VALIDATION,
    STAGE_EMBEDDING,
)
