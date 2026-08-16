"""Cross-session intelligence tests (architecture §4.9, spec §19).

Exercises the deterministic insights runner, the worker dispatch path, and the
dedicated `POST /api/v1/insights` surface. No LLM is involved: clustering over
shared entity/tag labels is the unit under test, and provenance (source
sessions + snippets) is asserted on every insight.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4

import pytest
from app.commands.insights_runner import run_insights
from app.errors import JobFailedError
from app.models import Job, JobKind, JobStatus
from app.store import get_store
from app.workers.orchestrator import process_job

SESSIONS: list[dict[str, object]] = [
    {
        "session_id": "s1",
        "title": "Benchmark planning",
        "entities": ["Benchmark Platform", "Release"],
        "tags": ["planning"],
        "summary": "We evaluated Benchmark Platform for staging.",
        "items": [
            {
                "title": "Adopt Benchmark",
                "description": "Run Benchmark Platform nightly.",
            }
        ],
    },
    {
        "session_id": "s2",
        "title": "Platform deep dive",
        "entities": ["benchmark platform", "Release"],
        "tags": ["research"],
        "summary": "Benchmark Platform capacity review.",
    },
    {
        "session_id": "s3",
        "title": "Infra notes",
        "entities": ["Docker"],
        "tags": ["planning", "research"],
        "summary": "Container image sizes.",
    },
]


def _insights_job(**options) -> Job:
    now = datetime.now(timezone.utc)
    return Job(
        id=str(uuid4()),
        user_id="u1",
        kind=JobKind.insights,
        status=JobStatus.queued,
        input_ref=None,
        options=options,
        created_at=now,
        updated_at=now,
    )


def _entity_insights(result: dict) -> list[dict]:
    return [i for i in result["insights"] if i["kind"] == "entity"]


def test_clusters_shared_entities_with_sources() -> None:
    result = run_insights(_insights_job(sessions=SESSIONS))

    entities = {i["label"]: i for i in _entity_insights(result)}
    # Casefold dedupe: "Benchmark Platform" + "benchmark platform" cluster.
    assert "Benchmark Platform" in entities
    insight = entities["Benchmark Platform"]
    assert insight["session_count"] == 2
    assert insight["confidence"] == 0.5
    assert insight["statement"] == "You've discussed Benchmark Platform in 2 sessions."
    assert {s["session_id"] for s in insight["sources"]} == {"s1", "s2"}
    for source in insight["sources"]:
        assert source["title"]
    # Snippet comes from item text / summary where the label appears.
    snippets = [s["snippet"] for s in insight["sources"] if s["snippet"]]
    assert snippets and all("Benchmark" in s for s in snippets)

    # "Release" also spans s1 + s2.
    assert entities["Release"]["session_count"] == 2


def test_single_session_label_is_not_an_insight() -> None:
    result = run_insights(_insights_job(sessions=SESSIONS))
    labels = {i["label"] for i in result["insights"]}
    assert "Docker" not in labels


def test_tags_are_insights_too() -> None:
    result = run_insights(_insights_job(sessions=SESSIONS))
    tags = {i["label"]: i for i in result["insights"] if i["kind"] == "tag"}
    assert tags["planning"]["session_count"] == 2
    assert tags["research"]["session_count"] == 2
    assert tags["planning"]["statement"] == (
        "You've used the tag 'planning' in 2 sessions."
    )


def test_insights_rank_by_evidence_then_label() -> None:
    sessions = [
        {
            "session_id": f"s{i}",
            "title": f"Session {i}",
            "entities": ["Common"],
            "tags": ["shared"],
        }
        for i in range(4)
    ]
    result = run_insights(_insights_job(sessions=sessions))
    order = [i["label"] for i in result["insights"]]
    assert order == ["Common", "shared"]
    assert result["insights"][0]["session_count"] == 4
    # Confidence grows with evidence: 0.5 + (4-2)*0.15 = 0.8.
    assert result["insights"][0]["confidence"] == 0.8


def test_max_insights_cap() -> None:
    sessions = [
        {
            "session_id": f"s{i}",
            "title": f"Session {i}",
            "tags": ["shared-a", "shared-b", "shared-c"],
        }
        for i in range(6)
    ]
    result = run_insights(_insights_job(sessions=sessions, max_insights=2))
    assert len(result["insights"]) == 2
    assert [i["label"] for i in result["insights"]] == ["shared-a", "shared-b"]


def test_missing_sessions_fails_structurally() -> None:
    with pytest.raises(JobFailedError) as exc:
        run_insights(_insights_job())
    assert exc.value.code == "INSIGHTS_CONTEXT_INVALID"


def test_empty_sessions_fails_structurally() -> None:
    with pytest.raises(JobFailedError) as exc:
        run_insights(_insights_job(sessions=[]))
    assert exc.value.code == "INSIGHTS_CONTEXT_INVALID"


def test_session_without_id_fails_structurally() -> None:
    with pytest.raises(JobFailedError) as exc:
        run_insights(_insights_job(sessions=[{"title": "no id"}]))
    assert exc.value.code == "INSIGHTS_CONTEXT_INVALID"


def test_result_validates_against_the_canonical_schema() -> None:
    from app.schemas import insights_schema, validate_against_schema

    result = run_insights(_insights_job(sessions=SESSIONS))
    validate_against_schema(result, insights_schema())


def test_min_sessions_threshold() -> None:
    result = run_insights(_insights_job(sessions=SESSIONS, min_sessions=3))
    assert result["insights"] == []  # every label spans <= 2 sessions


def test_process_job_dispatches_insights_kind() -> None:
    store = get_store()
    job = store.create(_insights_job(sessions=SESSIONS))

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.succeeded
    assert updated.result is not None
    assert updated.result["total_sessions"] == 3
    labels = [i["label"] for i in updated.result["insights"]]
    assert "Benchmark Platform" in labels


def test_process_job_missing_sessions_fails_structurally() -> None:
    store = get_store()
    job = store.create(_insights_job())

    process_job(job.id)

    updated = store.get(job.id)
    assert updated is not None
    assert updated.status == JobStatus.failed
    assert updated.error is not None
    assert updated.error.code == "INSIGHTS_CONTEXT_INVALID"


def test_create_insights_via_api() -> None:
    from app.main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    created = client.post(
        "/api/v1/insights",
        headers={"X-User-Id": "u1"},
        json={"sessions": SESSIONS},
    ).json()["data"]
    assert created["kind"] == "insights"
    assert created["status"] == "queued"

    job_id = created["id"]
    process_job(job_id)
    fetched = client.get(f"/api/v1/jobs/{job_id}", headers={"X-User-Id": "u1"}).json()[
        "data"
    ]
    assert fetched["status"] == "succeeded"
    labels = [i["label"] for i in fetched["result"]["insights"]]
    assert "Benchmark Platform" in labels


def test_create_insights_via_generic_jobs_api() -> None:
    from app.main import app
    from fastapi.testclient import TestClient

    client = TestClient(app)
    created = client.post(
        "/api/v1/jobs",
        headers={"X-User-Id": "u1"},
        json={"kind": "insights", "options": {"sessions": SESSIONS}},
    ).json()["data"]
    assert created["kind"] == "insights"

    job_id = created["id"]
    process_job(job_id)
    assert (
        client.get(f"/api/v1/jobs/{job_id}", headers={"X-User-Id": "u1"}).json()[
            "data"
        ]["status"]
        == "succeeded"
    )


def test_pattern_detection_person_project_task_decision() -> None:
    sessions = [
        {
            "session_id": "s1",
            "title": "Meeting 1",
            "entities": [
                {"name": "Alice Smith", "type": "person"},
                {"name": "Project Apollo", "type": "project"},
            ],
            "items": [
                {"title": "Review architecture", "type": "task"},
                {"title": "Use Supabase DB", "type": "decision"},
            ],
        },
        {
            "session_id": "s2",
            "title": "Meeting 2",
            "entities": [
                {"name": "Alice Smith", "type": "person"},
                {"name": "Project Apollo", "type": "project"},
            ],
            "items": [
                {"title": "Review architecture", "type": "task"},
                {"title": "Use Supabase DB", "type": "decision"},
            ],
        },
    ]
    result = run_insights(_insights_job(sessions=sessions))
    by_kind = {i["kind"]: i for i in result["insights"]}

    assert "person" in by_kind
    assert by_kind["person"]["label"] == "Alice Smith"
    assert "mentioned or met with Alice Smith" in by_kind["person"]["statement"]

    assert "project" in by_kind
    assert by_kind["project"]["label"] == "Project Apollo"
    assert "Project 'Project Apollo' appears" in by_kind["project"]["statement"]

    assert "task" in by_kind
    assert by_kind["task"]["label"] == "Review architecture"
    assert "Task 'Review architecture' recurs" in by_kind["task"]["statement"]

    assert "decision" in by_kind
    assert by_kind["decision"]["label"] == "Use Supabase DB"
    statement = by_kind["decision"]["statement"]
    assert "Decision regarding 'Use Supabase DB' recurs" in statement
