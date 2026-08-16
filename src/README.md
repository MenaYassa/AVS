# AI Knowledge Companion — Flutter app

Flutter client for the AI Knowledge Companion (architecture §3, spec §1). State
management via Riverpod, SQLite via drift, Supabase for cloud sync/storage/auth,
`record`/`just_audio` for capture and playback.

**Status:** Phases 1–3 done; Phase 4 in progress (P4-A search, P4-B organization,
P4-C playback + privacy shipped; P4-D graph browser pending). **227 tests green +
3 skipped, `flutter analyze` clean.** Drift schema v7 (FTS5 search, tags,
op-log, sync outbox/conflicts, session_versions, app_meta).

## Layout

Feature-first under `lib/`:

```
lib/
  app/        # bootstrap + provider overrides, go_router routes, theme
  core/       # shared UI + helpers
  domain/     # entities, repositories (seams), editing ops + op-log,
              # versioning, conflict resolver, use cases (pure Dart)
  data/       # drift database + DAOs, local data sources, sync engine,
              # engine HTTP/SSE client, search, contract (vendored schemas)
  features/   # per-feature controllers + screens/widgets:
              #   recording, analysis, auth, editing, versioning, home,
              #   search, organization, tags, playback, settings, sync
test/         # unit + widget tests (see AGENTS.md for conventions)
```

## Commands

```sh
~/flutter/flutter/bin/flutter analyze --no-pub
~/flutter/flutter/bin/flutter test --no-pub
dart run build_runner build --delete-conflicting-outputs   # after editing database.dart
```

## Testing conventions

- Real file IO inside `testWidgets` must be wrapped in `tester.runAsync(...)` —
  on this host real `dart:io` futures starve the fake-async test clock (see
  `test/features/session_detail_screen_test.dart`).
- Feature controllers are tested with fakes from `test/helpers/`
  (`FakeVoiceRecorder`, `FakeSessionAudioPlayer`, in-memory repositories).
- On-device `integration_test/` is scaffolded but blocked on this headless host
  (no emulator/device).

## Docs

See `docs/spec.md`, `docs/architecture.md` (binding baseline), and
`docs/Roadmap.md` for the full roadmap and milestone log.
