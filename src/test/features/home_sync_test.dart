import 'dart:async';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/sync/sync_engine.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/auth/auth_controller.dart';
import 'package:ai_knowledge_companion/features/home/home_screen.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _SignedInAuth implements AuthRepository {
  _SignedInAuth(this.userId);

  final String userId;

  @override
  String? get currentUserId => userId;

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

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

class _ControlledRemote implements SyncRepository {
  Completer<void>? gate;
  int pullCount = 0;
  bool failPull = false;

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async {
    pullCount++;
    final g = gate;
    if (g != null) await g.future;
    if (failPull) throw Exception('offline');
    return const [];
  }

  @override
  Future<void> pushSession(Session session) async {}

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {}

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async => null;

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

class _ThrowingEngine extends SyncEngine {
  _ThrowingEngine(AppDatabase db)
      : super(db: db, remote: _ControlledRemote());

  @override
  Future<SyncRunResult> sync({required String userId}) async {
    throw Exception('boom');
  }
}

Widget _app(List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: const MaterialApp(home: HomeScreen()),
    );

void main() {
  testWidgets('home shows syncing then last-sync summary while signed in',
      (tester) async {
    final remote = _ControlledRemote()..gate = Completer();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
      syncEngineProvider.overrideWithValue(SyncEngine(db: db, remote: remote)),
    ]));
    await tester.pump();

    expect(find.text('Syncing…'), findsOneWidget);

    remote.gate!.complete();
    remote.gate = null;
    await tester.pumpAndSettle();

    expect(find.textContaining('Synced at'), findsOneWidget);
  });

  testWidgets('pull-to-refresh triggers another sync pass', (tester) async {
    final remote = _ControlledRemote();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
      syncEngineProvider.overrideWithValue(SyncEngine(db: db, remote: remote)),
    ]));
    await tester.pumpAndSettle();
    expect(remote.pullCount, 1);

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(remote.pullCount, 2);
    expect(find.textContaining('Synced at'), findsOneWidget);
  });

  testWidgets('home surfaces a failed sync pass', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
      syncEngineProvider.overrideWithValue(_ThrowingEngine(db)),
    ]));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sync failed'), findsOneWidget);
  });

  testWidgets('no sync status line when signed out', (tester) async {
    await tester.pumpWidget(_app([
      databaseProvider.overrideWithValue(_FakeSessionRepository()),
      authRepositoryProvider.overrideWithValue(const NoopAuthRepository()),
    ]));
    await tester.pumpAndSettle();

    expect(find.textContaining('Synced at'), findsNothing);
    expect(find.textContaining('Syncing'), findsNothing);
  });
}
