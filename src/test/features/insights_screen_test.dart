import 'dart:async';
import 'dart:convert';

import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/insights/insights_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/analysis_fakes.dart';

Session _readySession(String id) => Session(
      id: id,
      userId: 'u1',
      title: 'Session $id',
      summary: 'Benchmark Platform notes.',
      status: SessionStatus.ready,
      entities: [
        GraphEntity(
          id: 'e$id',
          userId: 'u1',
          type: EntityType.organization,
          name: 'Benchmark Platform',
        ),
      ],
      topics: [
        Topic(
          id: 't$id',
          title: 'Topic',
          description: '',
          position: 0,
          items: [
            Item(
              id: 'i$id',
              type: ItemType.idea,
              title: 'Idea',
              description: 'About Benchmark Platform.',
              position: 0,
            ),
          ],
        ),
      ],
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );

class _FakeSessions implements SessionRepository {
  _FakeSessions(this.sessions);

  final List<Session> sessions;

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(sessions);

  @override
  Future<Session?> getSession(String id) async =>
      sessions.where((s) => s.id == id).firstOrNull;

  @override
  Future<Session> insertSession(Session session) async => session;

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async {}

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {}

  @override
  Future<List<Topic>> getTopics(String sessionId) async => const [];
}

class _FakeTags implements TagRepository {
  @override
  Future<List<Tag>> getAll() async => const [];

  @override
  Future<List<Tag>> getTagsForSession(String sessionId) async => const [];

  @override
  Stream<List<Tag>> watchTagsForSession(String sessionId) =>
      Stream.value(const []);

  @override
  Future<void> save(Tag tag) async {}

  @override
  Future<void> delete(String id) async {}

  @override
  Future<void> attachTag({required String sessionId, required String tagId}) async {}

  @override
  Future<void> detachTag({required String sessionId, required String tagId}) async {}

  @override
  Future<void> setSessionTags(String sessionId, List<String> tagIds) async {}
}

class _FakeJobs implements JobRepository {
  final List<Job> stored = [];

  @override
  Future<Job?> getJob(String id) async =>
      stored.where((j) => j.id == id).firstOrNull;

  @override
  Future<Job> insertJob(Job job) async {
    stored.add(job);
    return job;
  }

  @override
  Future<void> updateJob(Job job) async {
    final i = stored.indexWhere((j) => j.id == job.id);
    if (i >= 0) {
      stored[i] = job;
    } else {
      stored.add(job);
    }
  }

  @override
  Stream<Job?> watchJob(String id) =>
      Stream.value(stored.where((j) => j.id == id).firstOrNull);
}

class _FakeSettings implements AppSettingsRepository {
  _FakeSettings(this.enableInsights);

  final bool enableInsights;

  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async => false;

  @override
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value) async {}

  @override
  Future<bool> getEnableInsights(String userId) async => enableInsights;

  @override
  Future<void> setEnableInsights(String userId, bool value) async {}

  @override
  Future<bool> getEnableMemory(String userId) async => false;

  @override
  Future<void> setEnableMemory(String userId, bool value) async {}

  @override
  Future<bool> getMemorySkip(String sessionId) async => false;

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {}
}

class _SignedInAuth implements AuthRepository {
  @override
  String? get currentUserId => 'u1';

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

Widget _app(
  List<Override> overrides, {
  required Widget home,
}) {
  final router = GoRouter(
    initialLocation: '/insights',
    routes: [
      GoRoute(path: '/insights', builder: (_, _) => home),
      GoRoute(
        path: '/sessions/:id',
        builder: (_, state) => Scaffold(
          body: Text('detail:${state.pathParameters['id']}'),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(routerConfig: router),
  );
}

List<Override> _overrides({
  required _FakeSessions sessions,
  required FakeEngineGateway engine,
  required _FakeSettings settings,
}) =>
    [
      databaseProvider.overrideWithValue(sessions),
      jobProvider.overrideWithValue(_FakeJobs()),
      engineGatewayProvider.overrideWithValue(engine),
      tagRepositoryProvider.overrideWithValue(_FakeTags()),
      appSettingsRepositoryProvider.overrideWithValue(settings),
      authRepositoryProvider.overrideWithValue(_SignedInAuth()),
    ];

Map<String, dynamic> _resultJson() => {
      'insights': [
        {
          'kind': 'entity',
          'label': 'Benchmark Platform',
          'session_count': 2,
          'mention_count': 2,
          'confidence': 0.5,
          'statement': "You've discussed Benchmark Platform in 2 sessions.",
          'sources': [
            {'session_id': 's1', 'title': 'Session s1', 'snippet': 'About Benchmark Platform.'},
            {'session_id': 's2', 'title': 'Session s2', 'snippet': null},
          ],
        },
      ],
      'generated_at': '2026-08-10T05:20:03+00:00',
      'total_sessions': 2,
    };

void main() {
  testWidgets('shows the opt-in gate when insights are disabled', (tester) async {
    final engine = FakeEngineGateway();
    addTearDown(engine.closeStream);
    await tester.pumpWidget(_app(
      _overrides(
        sessions: _FakeSessions([_readySession('s1')]),
        engine: engine,
        settings: _FakeSettings(false),
      ),
      home: const InsightsScreen(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Cross-session insights'), findsOneWidget);
    expect(find.text('Enable insights'), findsOneWidget);
    // No job is created while disabled.
    expect(engine.createCount, 0);
  });

  testWidgets('runs a pass and renders insight cards with provenance',
      (tester) async {
    final engine = FakeEngineGateway();
    addTearDown(engine.closeStream);
    await tester.pumpWidget(_app(
      _overrides(
        sessions: _FakeSessions([_readySession('s1'), _readySession('s2')]),
        engine: engine,
        settings: _FakeSettings(true),
      ),
      home: const InsightsScreen(),
    ));
    // The auto-refresh runs through the async settings + descriptor chain;
    // all of its futures are pre-completed microtasks, so bounded pumps drive
    // it into the spinner state (which animates, so pumpAndSettle can't settle).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.insights);
    final shipped = engine.lastOptions!['sessions'] as List<dynamic>;
    expect(shipped, hasLength(2));
    expect(find.text('Looking across your sessions…'), findsOneWidget);

    // Stream the deterministic result through the SSE fake.
    engine.emit(engine.created!.copyWith(
      status: JobStatus.succeeded,
      resultJson: jsonEncode(_resultJson()),
      updatedAt: DateTime.now().toUtc(),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();

    expect(
      find.text("You've discussed Benchmark Platform in 2 sessions."),
      findsOneWidget,
    );
    expect(find.text('2 sessions'), findsOneWidget);
    expect(find.text('50% confidence'), findsOneWidget);
    expect(find.text('Sources'), findsOneWidget);
    // Provenance chips link back to the source sessions.
    expect(find.text('Session s1'), findsOneWidget);
    expect(find.text('Session s2'), findsOneWidget);
    expect(find.textContaining('About Benchmark Platform.'), findsOneWidget);

    // Tapping a source chip opens that session.
    await tester.tap(find.text('Session s1'));
    await tester.pumpAndSettle();
    expect(find.text('detail:s1'), findsOneWidget);
  });

  testWidgets('shows a friendly empty state when no sessions are analyzed',
      (tester) async {
    final engine = FakeEngineGateway();
    addTearDown(engine.closeStream);
    await tester.pumpWidget(_app(
      _overrides(
        sessions: _FakeSessions(const []),
        engine: engine,
        settings: _FakeSettings(true),
      ),
      home: const InsightsScreen(),
    ));
    await tester.pumpAndSettle();

    expect(engine.createCount, 0);
    expect(find.textContaining('No insights yet'), findsOneWidget);
    expect(find.text('Generate insights'), findsOneWidget);
  });
}
