# App Status — AI Knowledge Companion

Snapshot of project status as of **2026-08-16**. Source of truth: `docs/Roadmap.md` (milestone log), `docs/spec.md`, `docs/architecture.md` (binding).

## Overall

| Phase | Name | Status | Summary |
|---|---|---|---|
| 1 | Foundation (MVP) | 🟢 Complete* | Flutter scaffold, Auth (Supabase Google Sign-In), Local DB (Drift v10), Sync engine, Engine skeleton |
| 2 | AI Processing | 🟢 Complete* | 9-stage orchestrator, prompt registry, STT/LLM provider adapters, session lifecycle, SSE streams |
| 3 | Interactive Editing | 🟢 Done | Op-log undo/redo, version history & snapshots, diff sync, transcript editing & re-run |
| 4 | Knowledge Management | 🟢 Done | Global FTS5 search, organization (tags/favorites/archive/trash/pin), audio playback & privacy, knowledge graph browser |
| 5 | AI Productivity | 🟢 Done | AI command bus (11 commands), grounded session chat, cross-session insights, opt-in AI memory, multi-format export |
| 6 | Intelligence | 🟢 Feature-Complete | Semantic search (MiniLM-L6-v2 + pgvector), global knowledge map, plugin targets (Notion/Slack), universal inputs (voice/notes/OCR images/PDFs/emails/documents/screenshots), §6.5 quality testing harness |

*\* Phases 1–2 on-device instrumented runs (§1.8 E2E smoke, §2.5 on-device E2E, Fastlane) are infra-gated by headless host constraints; hermetic equivalents are 100% green.*

**Current Signal:**
- **Android App (`app/`)**: Jetpack Compose (Material 3), Room Database v3 persistence, Google Gemini integration (Flash-Lite / Pro Preview Thinking mode), Waveform Audio Player/Recorder, Document OCR parsing, soft-delete restoration preserving archive status, responsive multi-line topic card layout — **Build & Compilation 100% clean**.
- **Flutter Client (`src/`)**: **339 tests green + 3 skipped, `flutter analyze` clean**, Drift schema v10.
- **Python Engine (`engine/`)**: **317 pytest green, ruff clean**, 9-stage pipeline, universal input registry, Notion/Slack plugins.
- **Supabase Cloud Schema (`supabase/`)**: RLS policies, migrations, GIN full-text search, and recursive CTE graph traversal.

---

## 1. Subsystem Architecture

### 1.1 Android Compose Client (`app/`)
- **UI Architecture**: Jetpack Compose with Material 3 theming (`DeepSlate`, `SurfaceDark`, `EmeraldGreen`, `AmberAlert`, `SlateMuted`).
- **Data Persistence**: Room Database (`AppDatabase`) with `SessionDao`, `TopicDao`, `ItemDao`, `EntityDao`, `RelationDao`, `DraftDao`, `ChatMessageDao`.
  - **Soft-Delete / Restore**: `softDelete` sets `deleted = 1`, `undelete` sets `deleted = 0` (preserving `archived`, `pinned`, and `favorite` flags).
  - **Card Formatting**: Dynamic multi-line wrapping with top-aligned task status toggles and dedicated chip/action footer rows.
- **AI Integration**: Gemini REST client (`GeminiService`) with Markdown streaming, structured extraction, and Thinking Mode support.
- **Audio & Media**: Visualizer waveform recording (`VoiceRecordingScreen`), position-tracked playback with custom seekbars.
- **Universal Input Capture**: `DocumentCaptureScreen` with ML Kit / OCR preprocessing for images, PDFs, text, and documents.

### 1.2 Flutter Client (`src/`)
- **State Management & Routing**: Riverpod (`NotifierProvider`, `FamilyNotifier`), `go_router`.
- **Local Persistence**: Drift SQLite schema v10 (`sessions`, `topics`, `items`, `tags`, `session_tags`, `session_oplog`, `session_versions`, `sync_conflicts`, `entities`, `relationships`, `drafts`, `chat_messages`, `embeddings`, `app_meta`).
- **Editing & Synchronization**: Single mutation path via `EditSession`, cursor undo/redo `OperationLog`, diff-based outbox sync with anchor translation in `ConflictResolver`.
- **Knowledge Graph**: In-memory radial layout with SVG-like edge painter, BFS traversal, versioned graph editing ops (`AddEntity`, `RenameEntity`, `MergeEntities`, `DeleteEntity`, `AddRelationship`, `RelabelRelationship`, `DeleteRelationship`).

### 1.3 Knowledge Engine (`engine/`)
- **Pipeline Architecture**: 9-stage pipeline (Cleanup → Segmentation → Classification → Entity Extraction → Task Extraction → Knowledge Extraction → Tag Extraction → Validation → Embedding).
- **Universal Inputs**: Ingests `voice`, `transcript`, `note`, `image`, `pdf`, `email`, `document`, `screenshot` behind unified `InputDoc` protocol.
- **Plugins**: Server-side OAuth2 credential vault with outbound targets for Notion (`NotionPlugin`) and Slack (`SlackPlugin`).
- **Prompt Registry**: Byte-identical pinned prompt assets (`engine/prompts/*.json`) with runtime schema validation.

---

## 2. Milestone Summary

- **P1-A–P1-H**: Foundation scaffold, Drift v1–v3, Google auth, Voice recorder, Settings secret store, Supabase RLS.
- **P2-A–P2-I**: 7-stage pipeline, real STT/LLM provider adapters (Whisper, Deepgram, AssemblyAI, Anthropic, Gemini, OpenAI), SSE stream parsing, session lifecycle machine.
- **P3-A–P3-F**: Edit operations (15 ops), undo/redo op-log (schema v4), version history & snapshots, diff sync (schema v5), transcript editing and re-analysis.
- **P4-A–P4-D**: FTS5 global search (schema v6), organization & tags (schema v7), audio playback with privacy auto-deletion, knowledge graph browser (radial canvas, drift BFS, cloud CTE).
- **P5-A–P5-F**: AI command bus (11 commands, schema v8 drafts), grounded session chat (schema v9), cross-session insights, opt-in AI memory with provenance citations, multi-format export (TXT, MD, HTML, JSON).
- **P6-A–P6-H**: Semantic search (MiniLM-L6-v2 + drift v10 float32 embeddings + pure-Dart cosine ranking), global knowledge map, cross-session pattern detection, Notion/Slack plugins, universal inputs (manual notes, OCR images, PDFs, email, office docs, screenshots), §6.5 quality testing harnesses.

---

## 3. Verification & Health

- `app/`: Built and verified cleanly with `compile_applet`.
- `engine/`: `uv run ruff check .` and `uv run pytest` (317 tests passing).
- `src/`: `flutter analyze --no-pub` and `flutter test --no-pub` (339 tests passing).
