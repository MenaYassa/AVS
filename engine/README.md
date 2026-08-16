# AI Knowledge Engine

Python/FastAPI backend for the AI Knowledge Companion (architecture §4, §7.1).

**Status:** 8-stage AI pipeline live (cleanup → segmentation → classification →
entity_extraction → task_extraction → knowledge_extraction → tags → validation),
versioned prompt assets + immutable `PromptRegistry`, real STT/LLM provider
adapters with user-scoped keys, session lifecycle state machine, SSE progress,
universal input pipeline (voice + transcript), and the canonical JSON Schema
contract. **156 pytest green, ruff clean** (all tests hermetic; no Redis/network).

## Layout

```
app/
  main.py         # FastAPI app + middleware wiring
  config.py       # environment-driven settings
  errors.py       # structured error envelope
  models.py       # Pydantic models (job, envelope)
  auth.py         # Supabase JWT verification
  secrets.py      # per-user provider secret store (memory/Redis)
  store.py        # job persistence (memory or Redis)
  queue.py        # rq enqueue helpers
  blobstore.py    # blob fetching for STT (LocalBlobFetcher / SupabaseBlobFetcher)
  sse.py          # SSE event source (lifecycle progress + typed terminal events)
  lifecycle.py    # session lifecycle state machine (architecture §4.5)
  schemas.py      # loads/validates engine/schemas/*.json (single source of truth, §5.2)
  inputs/         # universal input pipeline: base, registry, voice, transcript
  prompts/        # versioned prompt assets (<stage>.<version>.json, §4.3)
  providers/      # LLM (OpenAI-compatible/Anthropic/Gemini) + STT (Whisper/Deepgram/AssemblyAI) adapters
  routers/        # health + jobs + providers endpoints
  stages/         # 8 single-responsibility pipeline stages + assembly + registry
  workers/        # orchestrator (resume-from-stage, idempotent) + worker entrypoint
tests/            # pytest suite (hermetic; in-memory job store by default)
```

## Run

```sh
uv sync                       # install deps (or: pip install -e '.[dev]' equivalent)
uv run uvicorn app.main:app --reload --port 8080
uv run ruff check .           # lint
uv run pytest                 # hermetic tests (in-memory job store)
```

With a queue (compose): set `ENGINE_JOB_STORE=redis` and `REDIS_URL`.
Workers: `uv run python -m app.workers.worker`.

## Pipeline & prompts

- 8 stages run in order: `cleanup → segmentation → classification →
  entity_extraction → task_extraction → knowledge_extraction → tags →
  validation` (architecture §4.2). The final stage assembles the canonical
  Session→Topics→Items JSON and validates it against `schemas.py`
  (`VALIDATION_FAILED` on breach).
- Stages resume from the last completed stage (`job.intermediates`), retry
  malformed LLM output once, and enforce token budgets.
- Every stage's instructions live in `prompts/<stage>.<version>.json`
  (architecture §4.3); versions are recorded in the canonical session's
  `prompt_versions`. Shipped prompts are pinned byte-for-byte in
  `tests/fixtures/prompts/` — in-place edits fail the contract tests.

## Universal input pipeline

Any job may carry an input kind (architecture §1.1, §4.12):

- `voice` — requires an `input_ref` (blob) → STT → pipeline.
- `transcript` — no `input_ref`; text travels in `options.input_meta.text`.

## Auth

- `SUPABASE_URL` set → every `/api/v1/*` request must carry
  `Authorization: Bearer <jwt>`; the engine verifies the Supabase access token
  (JWKS) and derives `user_id` from `sub`.
- `SUPABASE_URL` unset (local dev) → requests may use `X-User-Id` to identify a
  user; jobs are still ownership-scoped.
- Provider API keys are user-scoped via `secrets.py`; the app never stores keys.

## Envelope

All responses use `{ "status": "ok", "data": ... }` or
`{ "status": "error", "error": { "code", "message", "details" } }` (§7.1).
