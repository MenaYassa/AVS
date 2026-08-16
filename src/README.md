# AI Knowledge Companion — Flutter App

Flutter client for the AI Knowledge Companion (architecture §3, spec §1). Reactive state management via Riverpod, local SQLite persistence via Drift (schema v10), Supabase for cloud sync/storage/auth, audio recording & playback via `record`/`just_audio`, and local vector similarity search.

**Status:** Phases 1–6 Complete (§6.5 Quality Testing Milestone). **339 tests green + 3 skipped, `flutter analyze` clean.** Drift schema v10 (FTS5 search, tags, op-log, sync outbox/conflicts, session_versions, app_meta, drafts, chat_messages, embeddings).

## Architecture & Layout

Feature-first structure under `lib/`:

```
lib/
  app/        # bootstrap + provider overrides, go_router routes, theme
  core/       # audio player, voice recorder, document picker, secure storage, logging
  domain/     # entities (session, graph, draft, chat, insight, plugin, tag),
              # repositories (seams), editing ops (15 operations) + op-log,
              # session versioning & diffing, conflict resolver, use cases (pure Dart)
  data/       # drift database (schema v10) + DAOs, local data sources, sync engine,
              # engine HTTP/SSE client, FTS5 & semantic search data sources,
              # contract (vendored JSON schemas)
  features/   # per-feature controllers + screens/widgets:
              #   recording, analysis, auth, editing, versioning, home,
              #   search (FTS5 + semantic), organization, tags, playback,
              #   graph (local + global map), commands & drafts, chat,
              #   insights & patterns, notes, capture (image/PDF/email/doc),
              #   plugins (Notion/Slack), export, settings, sync
test/         # unit + widget tests (hermetic with memory repos & fakes)
```

## Key Client Capabilities

1. **Universal Capture**: Voice recording with live waveform, manual notes, OCR for images/PDFs, emails (`.eml`), and office documents (`.docx`, `.txt`, `.md`, `.rtf`).
2. **Interactive Editing & Versioning**: Op-log with bidirectional undo/redo (15 operations), point-in-time session versions, structural diff views, and conflict resolution.
3. **Knowledge Graph**: In-memory radial graph visualization, BFS neighborhood traversal, entity merging/renaming, and bidirectional relationship mapping.
4. **AI Productivity Bus**: Grounded session chat with memory context, 11 AI commands (summarize, extract action items, generate quiz, etc.) generating reviewable drafts, and multi-format export (Markdown, Text, HTML, JSON).
5. **Hybrid Search**: Full-Text Search (FTS5) combined with local float32 embedding cosine similarity ranking and background backfill.
6. **Plugin Outbox**: Outbound push integration with third-party targets (Notion & Slack).

## Commands

```sh
~/flutter/flutter/bin/flutter analyze --no-pub
~/flutter/flutter/bin/flutter test --no-pub
dart run build_runner build --delete-conflicting-outputs   # after editing database.dart
```

## Testing Conventions

- Real file IO inside `testWidgets` must be wrapped in `tester.runAsync(...)` to prevent real `dart:io` futures from stalling fake-async clocks.
- Controllers are tested with hermetic fakes from `test/helpers/` (`FakeVoiceRecorder`, `FakeSessionAudioPlayer`, in-memory repositories).
- 23-session realistic corpus retrieval quality tests verify Precision@5 thresholds.

## Documentation

See `docs/spec.md`, `docs/architecture.md` (binding baseline), and `docs/Roadmap.md` for complete product specs, architectural blueprints, and the milestone delivery log.
