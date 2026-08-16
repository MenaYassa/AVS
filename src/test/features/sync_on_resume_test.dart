import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/sync/sync_engine.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:ai_knowledge_companion/features/sync/sync_on_resume.dart';
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

class _FakeRemote implements SyncRepository {
  int pullCount = 0;

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async {
    pullCount++;
    return const [];
  }

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

void main() {
  testWidgets('resuming the app triggers a sync pass', (tester) async {
    final remote = _FakeRemote();
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: remote)),
      ],
      child: const SyncOnResume(child: SizedBox()),
    ));
    await tester.pump();

    expect(remote.pullCount, 0, reason: 'controller stays lazy until resume');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(remote.pullCount, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();

    expect(remote.pullCount, 2);

    // Reset the lifecycle so later tests start from a clean baseline.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
