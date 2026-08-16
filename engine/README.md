# AI Knowledge Engine — Python / FastAPI Backend

Python/FastAPI backend for the AI Knowledge Companion (architecture §4, §7.1).

**Status:** 9-stage AI pipeline live (cleanup → segmentation → classification → entity_extraction → task_extraction → knowledge_extraction → tags → validation → embedding), versioned prompt assets + immutable `PromptRegistry`, real STT/LLM provider adapters with user-scoped keys, session lifecycle state machine, SSE progress, universal input pipeline (voice, transcript, note, image, pdf, email, document, screenshot), plugin system (Notion, Slack), and canonical JSON Schema contract. **317 pytest green, ruff clean** (all tests hermetic; in-memory job store & mocks by default).

## Architecture & Layout

```
app/
  main.py         # FastAPI app factory + router mounts
  config.py       # environment-driven settings
  errors.py       # structured error envelope
  models.py       # Pydantic models (job, envelope, plugin, search)
  auth.py         # Supabase JWT verification
  secrets.py      # per-user provider secret store (memory/Redis)
  store.py        # job persistence (memory or Redis)
  events.py       # in-process event bus
  sse.py          # SSE event source (lifecycle progress + typed terminal events)
  lifecycle.py    # session lifecycle state machine (architecture §4.5)
  schemas.py      # loads/validates engine/schemas/*.json (single source of truth, §5.2)
  inputs/         # universal input pipeline: base, registry, voice, transcript, note, image, pdf, email, document, screenshot
  prompts/        # versioned prompt assets (<stage>.<version>.json, §4.3)
  providers/      # LLM (OpenAI-compatible/Anthropic/Gemini) + STT (Whisper/Deepgram/AssemblyAI) + OCR + DocumentParser adapters
  plugins/        # OAuth2 token storage & outbound push adapters (NotionPlugin, SlackPlugin)
  vector/         # pgvector & NullVectorStore adapters for semantic embeddings
  routers/        # health + jobs + providers + plugins + insights + search endpoints
  stages/         # 9 single-responsibility pipeline stages + assembly + registry + embedding stage
  workers/        # orchestrator (resume-from-stage, idempotent) + worker entrypoint
tests/            # pytest suite (hermetic; in-memory job store & test harnesses)
```

## Running & Developing

```sh
uv sync                       # install dependencies
uv run uvicorn app.main:app --reload --port 8080
uv run ruff check .           # linting
uv run pytest                 # hermetic test suite (317 tests)
```

With Redis queue enabled: set `ENGINE_JOB_STORE=redis` and `REDIS_URL`.
Start background worker: `uv run python -m app.workers.worker`.

## Pipeline & Prompts

- **9 Orchestrated Stages**: `cleanup → segmentation → classification → entity_extraction → task_extraction → knowledge_extraction → tags → validation → embedding` (architecture §4.2).
- **Validation**: The validation stage verifies output against canonical JSON schemas (`schemas.py`), raising `VALIDATION_FAILED` on contract breach.
- **Resumability**: Stages resume from the last completed stage (`job.intermediates`), retry malformed LLM outputs, and enforce strict token budgets.
- **Prompt Versioning**: Stage prompts are pinned in `prompts/<stage>.<version>.json`; prompt versions are stamped in the session output (`prompt_versions`). Contract tests in `tests/` guarantee prompt immutability.

## Universal Input Pipeline

Any job can specify an input format:
- `voice`: Blob reference → STT transcription → 9-stage analysis pipeline.
- `transcript`: Direct text in `options.input_meta.text`.
- `note`: Text notes directly routed to processing without audio artifacts.
- `image` / `screenshot`: OCR text extraction via `OcrProvider` seam.
- `pdf` / `email` / `document`: Parsed via `StdlibDocumentParser` supporting `.eml`, `.txt`, `.md`, `.rtf`, `.docx`, `.odt`, `.csv`, `.json`, `.xml`.

## Plugins & Outbound Integrations

- **Server-Side Token Vault**: Secure OAuth2 access token store.
- **Notion Target**: Formats structured sessions into multi-block Notion pages with toggle lists, tasks, and entity callouts.
- **Slack Target**: Posts markdown digests and actionable task lists to designated channels.

## Auth & Security

- `SUPABASE_URL` set: Every `/api/v1/*` request verifies the incoming JWT against Supabase JWKS.
- Local mode: Requests accept `X-User-Id` header for testing.
- Provider API keys are scoped per user and kept isolated from application code.

