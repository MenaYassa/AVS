import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:ai_knowledge_companion/domain/entities/plugin.dart';
import 'package:ai_knowledge_companion/domain/entities/semantic_search_result.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/search/embedding_backfill_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEmbeddingRepo implements EmbeddingRepository {
  List<String> missingIds = [];
  Map<String, List<double>> saved = {};

  @override
  Future<List<String>> sessionsWithoutLocalEmbedding() async => missingIds;

  @override
  Future<void> upsertSessionEmbedding({
    required String sessionId,
    required String scope,
    required String contentRef,
    required List<double> vector,
  }) async {
    saved[sessionId] = vector;
    missingIds.remove(sessionId);
  }

  @override
  Future<List<double>?> embeddingForSession(String sessionId) async => saved[sessionId];

  @override
  Future<void> deleteSessionEmbeddings(String sessionId) async {
    saved.remove(sessionId);
  }

  @override
  Future<List<SemanticSearchResult>> searchSimilar(
    List<double> queryVector, {
    int limit = 20,
    double threshold = 0.7,
    String? excludeSessionId,
  }) async => [];
}

class _FakeSessionRepo implements SessionRepository {
  final Map<String, Session> sessions = {};

  @override
  Future<Session?> getSession(String id) async => sessions[id];

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) => Stream.value(sessions.values.toList());

  @override
  Future<Session> insertSession(Session session) async {
    sessions[session.id] = session;
    return session;
  }

  @override
  Future<Session> updateSession(Session session, {bool emitDiff = true}) async {
    sessions[session.id] = session;
    return session;
  }

  @override
  Future<List<Topic>> getTopics(String sessionId) async => sessions[sessionId]?.topics ?? const [];

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {
    final current = sessions[sessionId];
    if (current != null) {
      sessions[sessionId] = current.copyWith(topics: topics);
    }
  }

  @override
  Future<void> deleteSession(String id) async {
    sessions.remove(id);
  }
}

class _FakeEngineGateway implements EngineGateway {
  List<({String sessionId, String text})> lastEmbedCall = [];
  bool fail = false;

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) async {
    if (fail) throw const EngineFailure('Cloud unreachable');
    lastEmbedCall = sessions;
    return EngineEmbedSessions(
      embeddings: [
        for (final s in sessions)
          EngineSessionEmbedding(
            sessionId: s.sessionId,
            embedding: [0.1, 0.2, 0.3],
            dimension: 3,
          ),
      ],
      dimension: 3,
    );
  }

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) => throw UnimplementedError();

  @override
  Future<Job> getJob(String userId, String jobId) => throw UnimplementedError();

  @override
  Future<void> cancelJob(String userId, String jobId) => throw UnimplementedError();

  @override
  Stream<Job> streamJob(String userId, String jobId) => const Stream.empty();

  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) => throw UnimplementedError();

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) =>
      throw UnimplementedError();

  @override
  Future<PluginAuthUrl> pluginAuthUrl(
    String userId,
    String kind, {
    required String redirectUri,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> exchangePluginToken(
    String userId,
    String kind, {
    required String code,
    required String state,
    required String redirectUri,
  }) =>
      throw UnimplementedError();

  @override
  Future<PluginPushReceipt> pushDraft(
    String userId,
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> disconnectPlugin(String userId, String kind) =>
      throw UnimplementedError();
}

void main() {
  late _FakeEmbeddingRepo embeddings;
  late _FakeSessionRepo sessionRepo;
  late _FakeEngineGateway engine;
  late ProviderContainer container;

  setUp(() {
    embeddings = _FakeEmbeddingRepo();
    sessionRepo = _FakeSessionRepo();
    engine = _FakeEngineGateway();

    container = ProviderContainer(
      overrides: [
        embeddingRepositoryProvider.overrideWithValue(embeddings),
        databaseProvider.overrideWithValue(sessionRepo),
        engineGatewayProvider.overrideWithValue(engine),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('build status initializes with the count of missing embeddings', () async {
    embeddings.missingIds = ['s1', 's2'];

    final status = await container.read(embeddingBackfillControllerProvider.future);

    expect(status.missing, 2);
    expect(status.inProgress, false);
    expect(status.embedded, 0);
    expect(status.error, null);
  });

  test('backfill fetches sessions, calls engine, and persists vectors', () async {
    embeddings.missingIds = ['s1', 's2'];
    sessionRepo.sessions['s1'] = const Session(
      id: 's1',
      userId: 'u1',
      title: 'Session One',
      summary: 'Summary one',
      status: SessionStatus.ready,
    );
    sessionRepo.sessions['s2'] = const Session(
      id: 's2',
      userId: 'u1',
      title: 'Session Two',
      topics: [Topic(id: 't1', title: 'Topic title', position: 0)],
      status: SessionStatus.ready,
    );

    final notifier = container.read(embeddingBackfillControllerProvider.notifier);
    await notifier.backfill();

    final status = container.read(embeddingBackfillControllerProvider).value!;
    expect(status.missing, 0);
    expect(status.inProgress, false);
    expect(status.embedded, 2);
    expect(status.error, null);

    expect(embeddings.saved['s1'], [0.1, 0.2, 0.3]);
    expect(embeddings.saved['s2'], [0.1, 0.2, 0.3]);

    expect(engine.lastEmbedCall.length, 2);
    expect(engine.lastEmbedCall[0].text, 'Session One | Summary one');
    expect(engine.lastEmbedCall[1].text, 'Session Two | Topic title');
  });

  test('backfill failure surfaces error but does not crash', () async {
    embeddings.missingIds = ['s1'];
    sessionRepo.sessions['s1'] = const Session(id: 's1', userId: 'u1', title: 'S1');
    engine.fail = true;

    final notifier = container.read(embeddingBackfillControllerProvider.notifier);
    await notifier.backfill();

    final status = container.read(embeddingBackfillControllerProvider).value!;
    expect(status.missing, 1);
    expect(status.inProgress, false);
    expect(status.embedded, 0);
    expect(status.error, 'Cloud unreachable');
  });
}
