import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSessionRepository implements SessionRepository {
  final List<Session> sessions = [];

  @override
  Future<void> deleteSession(String id) async {}

  @override
  Future<Session?> getSession(String id) async =>
      sessions.where((s) => s.id == id).firstOrNull;

  @override
  Future<List<Topic>> getTopics(String sessionId) async => const [];

  @override
  Future<Session> insertSession(Session session) async {
    sessions.add(session);
    return session;
  }

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {}

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async {}

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(List.of(sessions));
}

Widget _app(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: HomeScreen()),
    );

void main() {
  /// Taller viewport so multiple session tiles render without scrolling (the
  /// home list is lazy and off-screen tiles are not built).
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('home shows record button and empty state when signed out',
      (tester) async {
    final overrides = [
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ];

    await tester.pumpWidget(_app(overrides));
    await tester.pumpAndSettle();

    expect(find.text('Start Recording'), findsOneWidget);
    expect(find.text('Signed out'), findsOneWidget);
    expect(find.text('No sessions yet. Tap the mic and think out loud.'),
        findsOneWidget);
  });

  testWidgets('home offers a manual-note capture entry point',
      (tester) async {
    final overrides = [
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ];

    await tester.pumpWidget(_app(overrides));
    await tester.pumpAndSettle();

    expect(find.text('Write a note'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note_outlined), findsOneWidget);
  });

  testWidgets('home offers a document capture entry point (images/PDFs)',
      (tester) async {
    final overrides = [
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ];

    await tester.pumpWidget(_app(overrides));
    await tester.pumpAndSettle();

    expect(find.text('Import image/PDF'), findsOneWidget);
    expect(find.byIcon(Icons.file_upload_outlined), findsOneWidget);
  });

  testWidgets('home lists existing sessions with status chips',
      (tester) async {
    useTallViewport(tester);
    final repo = _FakeSessionRepository()
      ..sessions.add(Session(
        id: 's1',
        userId: 'u1',
        title: 'Product Ideas',
        status: SessionStatus.ready,
        createdAt: DateTime.now(),
      ))
      ..sessions.add(Session(
        id: 's2',
        userId: 'u1',
        title: 'Daily Brain Dump',
        status: SessionStatus.transcribing,
        createdAt: DateTime.now(),
      ));

    final overrides = [
      databaseProvider.overrideWithValue(repo),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ];

    await tester.pumpWidget(_app(overrides));
    await tester.pumpAndSettle();

    expect(find.text('Product Ideas'), findsOneWidget);
    expect(find.text('Daily Brain Dump'), findsOneWidget);
    expect(find.text('transcribing'), findsOneWidget);
  });

  testWidgets('favorites tab only shows starred, non-archived sessions',
      (tester) async {
    final repo = _FakeSessionRepository()
      ..sessions.add(Session(
        id: 's1',
        userId: 'u1',
        title: 'Starred',
        status: SessionStatus.ready,
        favorite: true,
        createdAt: DateTime.now(),
      ))
      ..sessions.add(Session(
        id: 's2',
        userId: 'u1',
        title: 'Archived Star',
        status: SessionStatus.ready,
        favorite: true,
        archived: true,
        createdAt: DateTime.now(),
      ))
      ..sessions.add(Session(
        id: 's3',
        userId: 'u1',
        title: 'Plain',
        status: SessionStatus.ready,
        createdAt: DateTime.now(),
      ));

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(repo),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();

    expect(find.text('Starred'), findsOneWidget);
    expect(find.text('Archived Star'), findsNothing);
    expect(find.text('Plain'), findsNothing);
  });

  testWidgets('archived tab shows archived sessions', (tester) async {
    final repo = _FakeSessionRepository()
      ..sessions.add(Session(
        id: 's1',
        userId: 'u1',
        title: 'Old Notes',
        status: SessionStatus.ready,
        archived: true,
        createdAt: DateTime.now(),
      ));

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(repo),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();

    expect(find.text('Old Notes'), findsOneWidget);
  });

  testWidgets('trash tab shows deleted sessions with restore affordances',
      (tester) async {
    final repo = _FakeSessionRepository()
      ..sessions.add(Session(
        id: 's1',
        userId: 'u1',
        title: 'Gone',
        status: SessionStatus.ready,
        deleted: true,
        createdAt: DateTime.now(),
      ));

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(repo),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trash'));
    await tester.pumpAndSettle();

    expect(find.text('Gone'), findsOneWidget);
    expect(find.byIcon(Icons.restore), findsOneWidget);
  });

  testWidgets('pinned sessions sort above newer unpinned ones', (tester) async {
    useTallViewport(tester);
    final repo = _FakeSessionRepository()
      ..sessions.add(Session(
        id: 'newer',
        userId: 'u1',
        title: 'Newer Unpinned',
        status: SessionStatus.ready,
        createdAt: DateTime.now(),
      ))
      ..sessions.add(Session(
        id: 'pinned-older',
        userId: 'u1',
        title: 'Pinned Old',
        status: SessionStatus.ready,
        pinned: true,
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
      ));

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(repo),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ]));
    await tester.pumpAndSettle();

    final yPinned = tester.getTopLeft(find.text('Pinned Old')).dy;
    final yNewer = tester.getTopLeft(find.text('Newer Unpinned')).dy;
    expect(yPinned, lessThan(yNewer));
  });
}
