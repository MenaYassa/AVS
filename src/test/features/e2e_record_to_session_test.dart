import 'dart:io';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/sync/sync_engine.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/home/home_screen.dart';
import 'package:ai_knowledge_companion/features/recording/recording_controller.dart';
import 'package:ai_knowledge_companion/features/session_detail/session_detail_screen.dart';
import 'package:ai_knowledge_companion/features/settings/settings_screen.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/analysis_fakes.dart';
import '../helpers/recording_fakes.dart';

/// Fresh router per test: the app-level [GoRouter] is a singleton whose
/// navigation state would otherwise leak between tests.
GoRouter _router() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/sessions/:id',
          builder: (_, state) =>
              SessionDetailScreen(sessionId: state.pathParameters['id']!),
        ),
        GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      ],
    );

/// Widget-level E2E (architecture §10, spec §28.2 DoD): record → engine mock →
/// structured session on screen, plus the failed-stage → resume path.
///
/// Mirrors the on-device `integration_test` flow (see `integration_test/`)
/// using the real router, real drift database, the fake voice recorder, and the
/// controllable [FakeEngineGateway] as the engine mock.
void main() {
  const resultJson =
      '{"schema_version":1,"session":{"id":"s1","title":"Q3 Budget",'
      '"alternative_titles":["Budget meeting"],'
      '"summary":"We reviewed the Q3 budget.",'
      '"status":"ready","prompt_versions":{},"topics":['
      '{"id":"t1","position":0,"title":"Budget","description":"","items":'
      '[{"id":"i1","type":"task","position":0,"title":"Finalize the budget",'
      '"description":"","priority":"high"}]}]}}';

  List<Override> overrides({
    required AppDatabase db,
    required FakeVoiceRecorder recorder,
    required FakeEngineGateway engine,
  }) {
    return <Override>[
      databaseProvider.overrideWithValue(SessionLocalDataSource(db)),
      jobProvider.overrideWithValue(JobLocalDataSource(db)),
      engineGatewayProvider.overrideWithValue(engine),
      versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
      syncProvider.overrideWithValue(_NoopSync()),
      syncEngineProvider.overrideWithValue(
          SyncEngine(db: db, remote: _NoopSync())),
      voiceRecorderProvider.overrideWithValue(recorder),
      recordingOutputDirectoryProvider.overrideWithValue(
        Future.value(Directory('/tmp/ai_voice_e2e')),
      ),
    ];
  }

  testWidgets('record → engine mock → structured session on screen',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final recorder = FakeVoiceRecorder();
    final engine = FakeEngineGateway();

    await tester.pumpWidget(ProviderScope(
      overrides: overrides(db: db, recorder: recorder, engine: engine),
      child: MaterialApp.router(routerConfig: _router()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump();
    expect(recorder.startCalls, 1);

    await tester.pump(const Duration(seconds: 2));
    await tester.tap(find.byIcon(Icons.stop_circle_outlined));
    await tester.pump();
    await tester.pump();

    expect(recorder.stopCalls, 1);
    expect(find.text('Untitled'), findsOneWidget);

    await tester.tap(find.text('Untitled'));
    await tester.pump();
    // Advance the page transition to completion (pumpAndSettle would hang on
    // the indeterminate progress indicator, so use fixed pumps).
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    // Analysis auto-submits on record stop (§2.4) — no manual Analyze needed.
    expect(engine.createCount, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    engine.emit(
        runningJob(engine.created!, 'cleanup', 'cleaning', 'Cleaning up'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cleaning up'), findsOneWidget);

    engine.emit(succeededJob(engine.created!, resultJson));
    await tester.pump();
    await tester.pump();

    expect(find.text('Q3 Budget'), findsOneWidget);
    expect(find.text('Budget meeting'), findsOneWidget);
    expect(find.text('We reviewed the Q3 budget.'), findsOneWidget);
    await tester.tap(find.text('Budget'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Finalize the budget'), findsOneWidget);
    expect(find.byIcon(Icons.flag), findsOneWidget);
    expect(find.text('Not analyzed yet'), findsNothing);

    // Unmount inside the body so drift's stream-close timer is flushed before
    // the framework's pending-timer invariant check.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('failed stage surfaces a retryable error, resume succeeds',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Draft',
      status: SessionStatus.ready,
      audioPath: '/tmp/s1.m4a',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    final recorder = FakeVoiceRecorder();
    final engine = FakeEngineGateway();

    await tester.pumpWidget(ProviderScope(
      overrides: overrides(db: db, recorder: recorder, engine: engine),
      child: MaterialApp.router(routerConfig: _router()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Draft'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyze'));
    await tester.pump();
    await tester.pump();

    engine.emit(
        runningJob(engine.created!, 'cleanup', 'cleaning', 'Cleaning up'));
    await tester.pump();
    await tester.pump();
    engine.emit(failedJob(engine.created!, 'boom'));
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Status: failed'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(engine.createCount, 2);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    engine.emit(
        runningJob(engine.created!, 'segmentation', 'analyzing', 'Analyzing'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Analyzing'), findsOneWidget);

    engine.emit(succeededJob(engine.created!, resultJson));
    await tester.pump();
    await tester.pump();

    expect(find.text('Q3 Budget'), findsOneWidget);
    await tester.tap(find.text('Budget'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Finalize the budget'), findsOneWidget);
    expect(find.text('Status: ready'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });
}

class _NoopSync implements SyncRepository {
  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async =>
      const [];

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async => null;

  @override
  Future<void> pushSession(Session session) async {}

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {}

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {}

  @override
  Future<void> pushTag(Tag tag) async {}

  @override
  Future<void> deleteTag({
    required String userId,
    required String tagId,
  }) async {}

  @override
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<List<Tag>> pullTags(String userId) async => const [];

  @override
  Future<List<SessionTag>> pullSessionTags(String userId) async => const [];
}
