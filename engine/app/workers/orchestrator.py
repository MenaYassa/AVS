"""AI pipeline orchestrator (architecture §4.2).

Runs the ordered stage chain for an `analyze` job:

1. Ingest the input blob through the universal input pipeline (§4.12) into a
   canonical `InputDoc`.
2. Resolve prompt versions (immutable, §4.3) and build configured stages.
3. Execute stages in order, persisting each completed stage's output to
   `job.intermediates` and the job's current `stage` — so a failure resumes
   from the last completed stage (resumability + idempotency, §2.1).
4. Return the validated canonical session (the `validation` stage output).

The worker entrypoint imports `process_job` via the fully-qualified name used
when enqueueing, so rq can resolve it in a subprocess.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any

from app.commands.chat_runner import run_chat
from app.commands.insights_runner import run_insights
from app.commands.runner import run_command
from app.config import settings
from app.errors import (
    EngineError,
    InvalidRequestError,
    JobCanceledError,
    JobFailedError,
)
from app.inputs.registry import get_input_source
from app.memory import normalize_memory
from app.models import ErrorDetail, Job, JobKind, JobStatus
from app.prompts.registry import get_prompt_registry
from app.stages.context import StageContext, TokenBudget
from app.stages.names import STAGE_VALIDATION
from app.stages.registry import build_stages, stage_pipeline
from app.store import get_store

logger = logging.getLogger(__name__)


async def _ingest(job: Job) -> dict[str, Any]:
    """Turn the job input into a canonical InputDoc (JSON-serializable)."""
    options = job.options or {}
    input_kind = options.get("input_kind") or "voice"
    input_ref = job.input_ref
    # Only blob-backed inputs need a ref; the text-only kinds (transcript
    # re-analysis and manual notes, §4.12) carry their text in
    # `input_meta.text` and are re-ingestible from nothing.
    if not input_ref and input_kind not in ("transcript", "note"):
        raise JobFailedError(
            "Job has no input_ref to ingest",
            code="INPUT_INVALID",
            details={"input_kind": input_kind},
        )
    source = get_input_source(
        input_kind,
        stt_provider=options.get("stt_provider"),
        user_id=job.user_id,
        ocr_provider=options.get("ocr_provider"),
        parser_provider=options.get("parser_provider"),
    )
    try:
        doc = await source.ingest(input_ref, options.get("input_meta") or {})
    except InvalidRequestError as exc:
        raise JobFailedError(
            exc.message, code="INPUT_INVALID", details=exc.details
        ) from exc
    if not doc.text.strip():
        raise JobFailedError(
            "Input produced an empty transcript",
            code="INPUT_INVALID",
            details={"input_kind": input_kind, "input_ref": input_ref},
        )
    doc.meta["job_id"] = job.id
    return doc


async def run_stages(job: Job) -> dict[str, Any]:
    """Execute the full pipeline for an analyze job; return the canonical session."""
    if job.kind != JobKind.analyze:
        raise JobFailedError(
            f"Pipeline supports kind 'analyze' only (got {job.kind.value})",
            code="UNSUPPORTED_JOB_KIND",
            details={"kind": job.kind.value},
        )

    options = job.options or {}
    # Validate the opt-in memory context up front so bad input fails fast,
    # before any STT/LLM spend (architecture §4.9).
    memory = normalize_memory(options.get("memory"))

    input_doc = await _ingest(job)
    prompt_registry = get_prompt_registry()
    prompt_versions = prompt_registry.resolve(stage_pipeline(), job.prompt_versions)
    budget = TokenBudget(
        max_input_tokens=settings.max_input_tokens,
        max_output_tokens=settings.max_output_tokens,
    )

    ctx = StageContext(
        input_doc=input_doc,
        prompt_versions=prompt_versions,
        budget=budget,
        memory=memory,
    )
    ctx.intermediates.update(job.intermediates or {})  # resume (idempotent)

    store = get_store()
    for stage in build_stages(prompt_registry, options, budget, user_id=job.user_id):
        current = store.get(job.id)
        if current is None:
            raise JobFailedError(
                "Job vanished while running the pipeline",
                code="JOB_NOT_FOUND",
            )
        if current.status == JobStatus.cancelled:
            raise JobCanceledError("Job cancelled during pipeline run")
        if stage.name in ctx.intermediates:
            continue  # already completed on a prior run
        ctx = await stage.run(ctx)
        store.update(
            current.with_updated(stage=stage.name, intermediates=ctx.intermediates)
        )

    return ctx.intermediates[STAGE_VALIDATION]


def _run_async(coroutine_factory: Any) -> Any:
    """Run a coroutine to completion in a synchronous, blocking way.

    Works whether or not the caller is already inside a running event loop
    (e.g. an async test under pytest-asyncio): a fresh loop is used directly
    when no loop is running, otherwise the coroutine runs on a dedicated loop
    in a worker thread and its outcome is raised/returned here.
    """

    def _execute() -> Any:
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(coroutine_factory())
        finally:
            loop.close()

    try:
        asyncio.get_running_loop()
        running = True
    except RuntimeError:
        running = False

    if not running:
        return _execute()

    outcome: dict[str, object] = {}

    def _target() -> None:
        try:
            outcome["result"] = _execute()
        except BaseException as exc:  # noqa: BLE001
            outcome["error"] = exc

    thread = threading.Thread(target=_target)
    thread.start()
    thread.join()
    if "error" in outcome:
        raise outcome["error"]  # type: ignore[misc]
    return outcome["result"]  # type: ignore[return-value]


def _run_pipeline(job: Job) -> dict[str, Any]:
    """Run the right execution path for the job kind, to completion.

    `analyze` runs the ordered stage chain; `command` and `chat` run
    single-shot AI operations over session context; `insights` runs
    deterministic cross-session clustering (architecture §4.9).
    """
    if job.kind == JobKind.command:
        return _run_async(lambda: run_command(job))
    if job.kind == JobKind.chat:
        return _run_async(lambda: run_chat(job))
    if job.kind == JobKind.insights:
        return run_insights(job)  # deterministic, no provider I/O (sync)
    return _run_async(lambda: run_stages(job))


def process_job(job_id: str) -> None:
    """rq worker entry. Runs the pipeline and persists outcome to the store."""
    store = get_store()
    job = store.get(job_id)
    if job is None:
        logger.error("worker: job %s not found", job_id)
        return
    if job.status.terminal:
        return

    store.update(job.with_updated(status=JobStatus.running))
    try:
        result = _run_pipeline(job)
        current = store.get(job_id) or job
        store.update(
            current.with_updated(
                status=JobStatus.succeeded,
                stage=None,
                result=result,
            )
        )
        logger.info("worker: job %s succeeded", job_id)
    except JobCanceledError as exc:
        current = store.get(job_id) or job
        store.update(
            current.with_updated(
                status=JobStatus.cancelled,
                error=ErrorDetail(
                    code=exc.code, message=exc.message, details=exc.details
                ),
            )
        )
    except JobFailedError as exc:
        current = store.get(job_id) or job
        store.update(
            current.with_updated(
                status=JobStatus.failed,
                error=ErrorDetail(
                    code=exc.code, message=exc.message, details=exc.details
                ),
            )
        )
        logger.info("worker: job %s failed (%s): %s", job_id, exc.code, exc.message)
    except EngineError as exc:
        current = store.get(job_id) or job
        store.update(
            current.with_updated(
                status=JobStatus.failed,
                error=ErrorDetail(
                    code=exc.code, message=exc.message, details=exc.details
                ),
            )
        )
        logger.info("worker: job %s failed (%s)", job_id, exc.code)
    except Exception as exc:  # noqa: BLE001
        current = store.get(job_id) or job
        store.update(
            current.with_updated(
                status=JobStatus.failed,
                error=ErrorDetail(code="INTERNAL_ERROR", message=str(exc)),
            )
        )
        logger.exception("worker: job %s crashed", job_id)


def start_worker() -> None:
    """Blocking worker loop for `python -m app.workers.worker` (rq, §9.2)."""
    if not settings.use_redis:
        raise SystemExit(
            "ENGINE_JOB_STORE must be 'redis' to run a worker "
            "(the in-memory store has no queue)"
        )
    from rq import Worker

    from app.queue import _connection

    Worker(queues=[settings.queue_name], connection=_connection()).work(
        with_scheduler=False
    )
