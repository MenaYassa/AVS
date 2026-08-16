import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/notes/note_editor_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../helpers/analysis_fakes.dart';

/// Records inserted sessions so the test can assert what the editor created.
class _RecordingSessionRepository implements SessionRepository {
  final List<Session> inserted = [];

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<Session?> getSession(String id) async =>
      inserted.where((s) => s.id == id).firstOrNull;

  @override
  Future<List<Topic>> getTopics(String sessionId) async => const [];

  @override
  Future<Session> insertSession(Session session) async {
    inserted.add(session);
    return session;
  }

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {}

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async {}

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(List.of(inserted));
}

/// Fresh router per test: the app-level [GoRouter] is a singleton whose
/// navigation state would otherwise leak between tests.
GoRouter _router() => GoRouter(
      initialLocation: '/note/new',
      routes: [
        GoRoute(path: '/note/new', builder: (_, _) => const NoteEditorScreen()),
        GoRoute(
          path: '/sessions/:id',
          builder: (_, state) => Scaffold(
            body: Text('detail:${state.pathParameters['id']}'),
          ),
        ),
      ],
    );

void main() {
  late AppDatabase db;
  late _RecordingSessionRepository sessions;
  late FakeEngineGateway engine;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = _RecordingSessionRepository();
    engine = FakeEngineGateway();
  });

  tearDown(() async {
    engine.closeStream();
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(JobLocalDataSource(db)),
        engineGatewayProvider.overrideWithValue(engine),
        authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
      ],
      child: MaterialApp.router(routerConfig: _router()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('saving a note creates a session, analyzes it, and navigates',
      (tester) async {
    await pumpApp(tester);

    await tester.enterText(
      find.byType(TextField).first,
      'Offsite prep',
    );
    await tester.enterText(
      find.byType(TextField).last,
      'Book flights and draft the agenda.',
    );
    await tester.tap(find.byKey(const ValueKey('save-note')));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, isNull);
    expect(engine.lastOptions!['input_kind'], 'note');
    expect(engine.lastOptions!['input_meta'], {
      'text': 'Book flights and draft the agenda.',
      'title': 'Offsite prep',
    });

    final created = sessions.inserted.single;
    expect(created.title, 'Offsite prep');
    expect(created.originalTranscript, 'Book flights and draft the agenda.');
    expect(created.status, SessionStatus.cleaning);

    // Landed on the session detail screen for the new session.
    expect(find.text('detail:${created.id}'), findsOneWidget);

    // Unmount so the analysis stream subscription is torn down cleanly.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('an empty note does nothing', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byKey(const ValueKey('save-note')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(engine.createCount, 0);
    expect(sessions.inserted, isEmpty);
    expect(find.text('detail:'), findsNothing);
  });
}
