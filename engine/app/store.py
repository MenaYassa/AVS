"""Job persistence. Hermetic in-memory store by default; Redis-backed with
`ENGINE_JOB_STORE=redis` (the compose topology). Redis also serves as the rq
queue for the worker (architecture §4.2, §9.2).
"""

from __future__ import annotations

import json
from typing import Any

from app.config import settings
from app.models import Job


class JobStore:
    """Minimal durable interface. Both backends keep job records JSON-serialized."""

    def create(self, job: Job) -> Job: ...
    def get(self, job_id: str) -> Job | None: ...
    def update(self, job: Job) -> Job: ...
    def list_by_user(self, user_id: str) -> list[Job]: ...


class MemoryJobStore(JobStore):
    def __init__(self) -> None:
        self._jobs: dict[str, dict[str, Any]] = {}
        self._by_user: dict[str, set[str]] = {}

    def create(self, job: Job) -> Job:
        self._jobs[job.id] = job.model_dump(mode="json", exclude_none=True)
        self._by_user.setdefault(job.user_id, set()).add(job.id)
        return job

    def get(self, job_id: str) -> Job | None:
        raw = self._jobs.get(job_id)
        return Job.model_validate(raw) if raw is not None else None

    def update(self, job: Job) -> Job:
        self._jobs[job.id] = job.model_dump(mode="json", exclude_none=True)
        return job

    def list_by_user(self, user_id: str) -> list[Job]:
        ids = sorted(self._by_user.get(user_id, set()))
        return [self.get(job_id) for job_id in ids if (self.get(job_id))]  # type: ignore[misc]


class RedisJobStore(JobStore):
    KEY_PREFIX = "engine:job:"
    USER_INDEX = "engine:jobs:"

    def __init__(self, redis_client: Any) -> None:
        self._r = redis_client

    @staticmethod
    def _key(job_id: str) -> str:
        return f"{RedisJobStore.KEY_PREFIX}{job_id}"

    def create(self, job: Job) -> Job:
        self._r.hset(
            self._key(job.id),
            "data",
            json.dumps(job.model_dump(mode="json", exclude_none=True), default=str),
        )
        self._r.sadd(f"{self.USER_INDEX}{job.user_id}", job.id)
        return job

    def get(self, job_id: str) -> Job | None:
        raw = self._r.hget(self._key(job_id), "data")
        return Job.model_validate(json.loads(raw)) if raw else None

    def update(self, job: Job) -> Job:
        self._r.hset(
            self._key(job.id),
            "data",
            json.dumps(job.model_dump(mode="json", exclude_none=True), default=str),
        )
        return job

    def list_by_user(self, user_id: str) -> list[Job]:
        ids = sorted(self._r.smembers(f"{self.USER_INDEX}{user_id}") or set())
        return [self.get(job_id) for job_id in ids if (self.get(job_id))]  # type: ignore[misc]


_store: JobStore | None = None


def get_store() -> JobStore:
    global _store
    if _store is None:
        if settings.use_redis:
            import redis as redis_lib

            _store = RedisJobStore(redis_lib.from_url(settings.redis_url))
        else:
            _store = MemoryJobStore()
    return _store
