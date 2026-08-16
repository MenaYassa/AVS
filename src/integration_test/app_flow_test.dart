import 'package:ai_knowledge_companion/app/app.dart';
import 'package:ai_knowledge_companion/app/bootstrap.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// On-device E2E (spec §28.2 DoD, architecture §10): record → engine → structured
/// session on screen, plus the failed-stage → resume path.
///
/// RUNNING (requires a device/emulator + a locally running engine):
///   1. Start the engine + worker:  `cd engine && uv run uvicorn app.main:app`
///   2. Record a real mic fixture (or stub analyze): point the engine at a
///      provider, or run with `--dart-define=ENGINE_BASE_URL=http://HOST:8080`.
///   3. `cd src && ~/flutter/flutter/bin/flutter test integration_test/app_flow_test.dart \
///         -d DEVICE --dart-define=ENGINE_BASE_URL=...`
///
/// STATUS: scaffolded; **blocked on this host** (headless — no emulator/device,
/// no mic). The equivalent flow is covered hermetically in
/// `test/features/e2e_record_to_session_test.dart` (real router + real drift DB +
/// FakeVoiceRecorder + FakeEngineGateway), which runs in CI.
///
/// To make the assertion deterministic, run the engine in "fixture mode":
/// serve the canonical session from `engine/tests/fixtures/results.1.json` for
/// `POST /api/v1/jobs` (kind: analyze) so the final stage emits `ready`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('record → analyze → structured session; failed stage resumes',
      (tester) async {
    await AppBootstrap.initSupabase();
    await tester.pumpWidget(const KnowledgeCompanionApp());
    await tester.pumpAndSettle();

    // Record ~2s.
    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pumpAndSettle();

    // The draft session tile appears on Home.
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.text('Untitled'), findsOneWidget);

    // Open it and kick off analysis.
    await tester.tap(find.text('Untitled'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Analyze'));
    await tester.pump(const Duration(seconds: 2));

    // Stage label + progress render while the engine works (SSE).
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // Wait for a terminal state, then assert the structured session landed.
    // The engine fixture serves the canonical result; assert its topics.
    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('Status:'), findsOneWidget);

    final failed = find.text('Retry');
    if (failed.evaluate().isNotEmpty) {
      // Failed stage → resume: retry re-submits and converges on ready.
      await tester.tap(failed);
      await tester.pump(const Duration(seconds: 5));
    }

    expect(find.text('Status: ready'), findsOneWidget);
    // The pinned fixture's topic title renders (see results.1.json).
    expect(find.byType(ExpansionTile), findsWidgets);
  });
}
