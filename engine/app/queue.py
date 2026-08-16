"""rq queue integration. Enqueues job ids for the orchestrator worker.

With the in-memory job store (dev/tests) enqueue is a no-op — jobs can be
processed in-process by calling the worker function directly. The compose
topology uses Redis for both store and queue.
"""

from __future__ import annotations

from app.config import settings
from app.models import Job

_PROCESSOR_FUNCTION = "app.workers.orchestrator.process_job"

_redis_connection = None


def _connection():
    global _redis_connection
    if _redis_connection is None:
        import redis

        _redis_connection = redis.from_url(settings.redis_url)
    return _redis_connection


def enqueue(job: Job) -> None:
    if not settings.use_redis:
        return
    from rq import Queue

    Queue(settings.queue_name, connection=_connection()).enqueue(
        _PROCESSOR_FUNCTION, job.id, job_timeout="1h"
    )
