import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/domain/usecases/manage_sessions.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSessionRepository implements SessionRepository {
  final Map<String, Session> store = {};

  @override
  Future<void> deleteSession(String id) async => store.remove(id);

  @override
  Future<Session?> getSession(String id) async => store[id];

  @override
  Future<List<Topic>> getTopics(String sessionId) async =>
      store[sessionId]?.topics ?? const [];

  @override
  Future<Session> insertSession(Session session) async {
    store[session.id] = session;
    return session;
  }

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {
    final s = store[sessionId];
    if (s != null) store[sessionId] = s.copyWith(topics: topics);
  }

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async =>
      store[session.id] = session;

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(store.values.toList());
}

void main() {
  group('StartSessionDraft', () {
    test('creates a recording draft with a fresh id and timestamps', () async {
      final repo = _FakeSessionRepository();
      final draft = await StartSessionDraft(repo)(userId: 'u1');

      expect(draft.id, isNotEmpty);
      expect(draft.userId, 'u1');
      expect(draft.status, SessionStatus.recording);
      expect(draft.createdAt, isNotNull);
      expect(draft.topics, isEmpty);
      expect(repo.store.containsKey(draft.id), isTrue);
    });

    test('supports signed-out capture with local owner', () async {
      final repo = _FakeSessionRepository();
      final draft = await StartSessionDraft(repo)(userId: null);
      expect(draft.userId, 'local');
      expect(draft.status, SessionStatus.recording);
    });
  });

  group('TransitionSessionStatus', () {
    test('advances lifecycle and persists the new state', () async {
      final repo = _FakeSessionRepository();
      final draft = await StartSessionDraft(repo)(userId: 'u1');

      final transitioned = await TransitionSessionStatus(repo)(
        draft,
        SessionStatus.uploading,
      );

      expect(transitioned.status, SessionStatus.uploading);
      expect(repo.store[draft.id]!.status, SessionStatus.uploading);
      expect(transitioned.updatedAt, isNotNull);
    });
  });
}
