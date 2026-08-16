# AGENTS.md

## Project state
- Live Flutter app in `src/` and FastAPI engine in `engine/`. Git history exists up to **P6-H** — this is the **P6-H §6.5 (quality testing) milestone**; a follow-up closed out the last §6.4 code item (screenshots input).
- **Flutter: 339 tests green + 3 skipped, `flutter analyze` clean.** Drift schema v10 (FTS5 search, tags, op-log, sync outbox/conflicts, session_versions, app_meta, drafts, chat_messages, embeddings).
- **Engine: 317 pytest green, ruff clean.** 9-stage pipeline (… → validation → embedding) + prompt registry + provider adapters (STT + OCR + parsers) + lifecycle + pgvector/Null vector store + plugins (OAuth2 Notion/Slack targets, push router) + universal inputs (voice, transcript, note, image, pdf, email, document, screenshot) + quality harnesses (token-overlap retrieval quality, graph scale smoke, plugin/document goldens).
- Phases 1–3 done; Phase 4–5 shipped (P4-A search, P4-B organization, P4-C playback + privacy, P4-D graph, P5-A commands, P5-B chat, P5-C insights, P5-D memory, P5-E export, P5-F testing gap); **P6-A semantic search shipped**. **P6-B shipped** (backfill + related sessions + global graph browse). **P6-C shipped** (§6.2 complete: cross-session pattern detection — recurring projects, people, open tasks, repeated decisions as first-class insights). **P6-D shipped** (§6.3 complete: plugin system — server-side OAuth2 credential store + Notion/Slack targets + Settings connect/disconnect + Draft-screen "Push to plugin"). **P6-E shipped** (§6.4 part 1: manual notes — `note` universal-input adapter, no STT/input_ref; `NoteEditorScreen` + home "Write a note"). **P6-F shipped** (§6.4 part 2: images/PDFs — OCR preprocessing seam `OcrProvider`/`PlaceholderOcrProvider` + `image`/`pdf` adapters (real OCR adapter still Phase 2), Flutter `DocumentPicker` + `analyzeDocument` + home "Import image/PDF" sheet). **P6-G shipped** (§6.4 part 3: emails/docs — `DocumentParser` seam + real stdlib `StdlibDocumentParser` (txt/md/html/eml/rtf/docx/odt/csv/json/xml) + `PlaceholderDocumentParserProvider` + `email`/`document` adapters, Flutter `pickEmail`/`pickDocument` + "Email file"/"Document" sheet entries). **P6-H shipped** (§6.5: quality tests — engine token-overlap retrieval-quality harness + API/embedding-stage quality assertions, Flutter 23-session corpus Precision@5, graph scale smoke (1 000 entities × 5 000 relationships), recorded plugin fixtures + request-contract tests, on-disk document/PDF parsing goldens; real OCR adapters remain Phase 2). Still pending in §6.4: screenshots (ride the image/OCR path), multi-input sessions (deferred: "if validated by usage"). Remaining Phase 1–2 gaps are device-blocked (E2E smoke, Fastlane, on-device E2E), not code.

## Commands
- Flutter (from `src/`): `~/flutter/flutter/bin/flutter analyze --no-pub` and `~/flutter/flutter/bin/flutter test --no-pub`. No `pub get` is needed between pure-source edits.
- Engine (from `engine/`): `uv run ruff check .` and `uv run pytest`. All engine tests are hermetic (in-memory job store; no Redis).
- Flutter tests that touch real file IO inside `testWidgets` must wrap the IO in `tester.runAsync(...)` — on this host, real `dart:io` futures starve the fake-async test clock (see `test/features/session_detail_screen_test.dart`).
- Generated drift code: after editing `lib/data/local/database.dart`, run `dart run build_runner build --delete-conflicting-outputs` from `src/`. **Note: `build_runner` AOT-compiles its builders for 10+ minutes (often >15) on this arm64 host before producing output — it does not appear to hang, just slow; run it detached (`setsid nohup … &`) and poll the log. Prefer avoiding DAO regeneration entirely when possible (implement queries directly via `_db.select(_db.<table>)` / `_db.into(_db.<table>)` — the generated table getters/data classes already exist for all tables in the `tables` list, so no codegen is needed for new hand-written data sources).**
- Schema contract: engine schemas are vendored to `src/lib/data/contract/` via `engine/scripts/vendor_schemas.py`; CI fails on drift.

## Source of truth (read before implementing)
- `docs/spec.md` — authoritative product spec ("AI Voice Knowledge Companion"): behavior, data model, roadmap.
- `docs/architecture.md` — **user-approved project baseline. Binding.** Future implementation MUST follow it. Any deviation requires explicit user approval first. It defines the full stack (frontend, engine, DB, auth, APIs, deployment, Docker, testing) and the AI Knowledge Engine model.
- `docs/Roadmap.md` — phased task breakdown with status checkboxes and a milestone log. **Update it in the same change that completes a milestone** (tick tasks, move phase status, append log row).

## Binding architecture (from `docs/architecture.md`)
- Framing: this is an **AI Knowledge Engine**, not a voice recorder. Voice is the first of many input adapters behind a Universal Input Pipeline (§1.1, §4.12).
- Flutter app, Riverpod state management, SQLite via drift, `flutter_secure_storage`, `record`/`just_audio`, go_router. Clean architecture: Presentation → Domain → Data; repository interfaces in Domain.
- Cloud backend: **Supabase** (Postgres + RLS + Storage + Realtime + pgvector), not Firebase. Sync layer abstracted so a swap stays possible.
- Backend: **AI Knowledge Engine** (Python/FastAPI + Redis queue + containerized workers). The app NEVER calls STT/LLM providers directly — all AI traffic goes through the engine.
- AI pipeline is an **orchestrated chain of single-responsibility, independently replaceable stages** (cleanup → segmentation → classification → entity extraction → task extraction → knowledge extraction → tags → validation), pure, resumable from last completed stage (§4.2).
- **Prompts are versioned assets, not code** (`engine/prompts/<stage>.<version>.json`); every session records `prompt_versions` in canonical JSON; re-runs create new versions (§4.3).
- Session lifecycle state machine: `recording → uploading → transcribing → cleaning → analyzing → validating → ready → edited → synced`, with structured failure + resume (§4.5).
- **Version history** (session_versions snapshots + restore), **knowledge graph** (entities/relationships, first-class subsystem), **cross-session intelligence + AI memory** (both opt-in, provenance-tracked), **AI command bus** (drafts, never auto-applied), **plugin adapter interface** (§4.6–4.11).
- Canonical data format is structured JSON (Session → Topics → Items) with confidence + prompt-version provenance. Never use Markdown as the source of truth — export only.
- All AI output must be user-editable, including the graph and confidence; AI never locks content.
- Shared JSON Schema contract: `engine/schemas/*.json` is the single source of truth; Flutter vendors a generated copy; CI contract test enforces parity (§5.2).

## Implementation order
- Follow the six-phase roadmap in spec §28 and the per-phase mapping in architecture §13: Foundation/MVP → AI Processing → Interactive Editing → Knowledge Management → AI Productivity → Intelligence.

## Layout
- App code lives in `src/` (feature-first `src/lib/`, tests in `src/test/`, on-device `src/integration_test/`); engine code in `engine/` (FastAPI app + `engine/tests/`); cloud SQL in `supabase/migrations/`. Follow the per-feature layout defined in architecture §3.3 and the engine module layout in §4.2.
