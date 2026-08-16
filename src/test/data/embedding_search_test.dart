import 'dart:typed_data';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/local/vector_codec.dart';
import 'package:ai_knowledge_companion/data/search/semantic_search_data_sources.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/job.dart';
import 'package:ai_knowledge_companion/domain/entities/plugin.dart';
import 'package:ai_knowledge_companion/domain/entities/semantic_search_result.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _memDb() => AppDatabase(NativeDatabase.memory());

Session _session(String id, {String? title, String? summary}) => Session(
      id: id,
      userId: 'u1',
      title: title,
      summary: summary,
      status: SessionStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

void main() {
  group('vector_codec', () {
    test('encodeFloat32/decodeFloat32 round-trip', () {
      final values = [0.5, -1.25, 3.0, 0.0, 1.5, -0.75];
      final bytes = encodeFloat32(values);
      expect(bytes, isA<Uint8List>());
      expect(bytes.length, values.length * 4);
      expect(decodeFloat32(bytes), values);
    });

    test('decodeFloat32 returns float32-quantized values', () {
      final decoded = decodeFloat32(encodeFloat32([0.1]));
      expect(decoded.single, closeTo(0.1, 1e-7));
    });

    test('cosine similarity ranks related vectors higher', () {
      final a = fakeEmbedding('recap of the q3 budget meeting');
      final b = fakeEmbedding('budget and financial planning recap');
      final c = fakeEmbedding('recipe for sourdough bread');

      final simAB = cosineSimilarity(a, b);
      final simAC = cosineSimilarity(a, c);
      expect(simAB, greaterThan(simAC));

      expect(cosineSimilarity(a, a), closeTo(1.0, 1e-9));
      expect(cosineSimilarity(a, const []), 0);
      expect(cosineSimilarity(a, fakeEmbedding('short', dimensions: 8)), 0);
    });
  });

  group('EmbeddingLocalDataSource', () {
    late AppDatabase db;
    late EmbeddingLocalDataSource ds;
    late SessionLocalDataSource sessions;

    setUp(() {
      db = _memDb();
      ds = EmbeddingLocalDataSource(db);
      sessions = SessionLocalDataSource(db);
    });
    tearDown(() => db.close());

    test('upsert round-trips through the blob column', () async {
      await sessions.insertSession(_session('s1', title: 'Budget'));
      await ds.upsertSessionEmbedding(
        sessionId: 's1',
        scope: 'local',
        contentRef: '1200',
        vector: fakeEmbedding('budget recap'),
      );

      final vector = await ds.embeddingForSession('s1');
      expect(vector, isNotNull);
      expect(vector!.length, 384);
      expect(cosineSimilarity(vector, fakeEmbedding('budget recap')),
          closeTo(1.0, 1e-9));
    });

    test('re-upsert replaces the previous vector (keyed by id)', () async {
      await sessions.insertSession(_session('s1', title: 'Budget'));
      await ds.upsertSessionEmbedding(
        sessionId: 's1',
        scope: 'local',
        contentRef: 'old',
        vector: fakeEmbedding('old content'),
      );
      await ds.upsertSessionEmbedding(
        sessionId: 's1',
        scope: 'local',
        contentRef: 'new',
        vector: fakeEmbedding('new content'),
      );

      final rows = await (db.select(db.embeddings)).get();
      expect(rows, hasLength(1));
      expect(rows.single.contentRef, 'new');
    });

    test('searchSimilar ranks by cosine and excludes the session', () async {
      await sessions.insertSession(_session('s1', title: 'Budget recap', summary: 'numbers'));
      await sessions.insertSession(_session('s2', title: 'Sourdough recipe', summary: 'bread'));
      final query = fakeEmbedding('quarterly budget numbers');

      await ds.upsertSessionEmbedding(
          sessionId: 's1',
          scope: 'local',
          contentRef: '',
          vector: fakeEmbedding('quarterly budget numbers'));
      await ds.upsertSessionEmbedding(
          sessionId: 's2',
          scope: 'local',
          contentRef: '',
          vector: fakeEmbedding('baking sourdough bread'));

      final results = await ds.searchSimilar(query, threshold: -1.0);
      expect(results.map((r) => r.sessionId), ['s1', 's2']);
      expect(results.first.title, 'Budget recap');
      expect(results.first.status, SessionStatus.ready);

      final excluding = await ds.searchSimilar(
        query,
        excludeSessionId: 's1',
        threshold: -1.0,
      );
      expect(excluding.map((r) => r.sessionId), ['s2']);
    });

    test('searchSimilar applies the similarity threshold', () async {
      await sessions.insertSession(_session('s1', title: 'A'));
      await sessions.insertSession(_session('s2', title: 'B'));
      final query = fakeEmbedding('needle');

      await ds.upsertSessionEmbedding(
          sessionId: 's1', scope: 'local', contentRef: '', vector: query);
      await ds.upsertSessionEmbedding(
          sessionId: 's2',
          scope: 'local',
          contentRef: '',
          vector: fakeEmbedding('unrelated topic'));

      expect(await ds.searchSimilar(query, threshold: 0.99),
          hasLength(1));
      expect(await ds.searchSimilar(query, threshold: 1.01), isEmpty);
    });

    test('deleteSessionEmbeddings removes vectors', () async {
      await sessions.insertSession(_session('s1', title: 'A'));
      await ds.upsertSessionEmbedding(
          sessionId: 's1',
          scope: 'local',
          contentRef: '',
          vector: fakeEmbedding('x'));
      expect(await ds.embeddingForSession('s1'), isNotNull);

      await ds.deleteSessionEmbeddings('s1');
      expect(await ds.embeddingForSession('s1'), isNull);
    });

    test('deleting a session also removes its embeddings', () async {
      final sessions = SessionLocalDataSource(db);
      await sessions.insertSession(_session('s1', title: 'A'));
      await ds.upsertSessionEmbedding(
          sessionId: 's1',
          scope: 'local',
          contentRef: '',
          vector: fakeEmbedding('x'));

      await sessions.deleteSession('s1');
      expect(await ds.embeddingForSession('s1'), isNull);
    });
  });

  group('HybridSemanticSearchRepository', () {
    test('merges local and engine results, deduped by session id', () async {
      final repo = HybridSemanticSearchRepository(
        engine: _FakeEngineGateway([
          const SemanticSearchResult(
            sessionId: 'cloud',
            title: 'Cloud hit',
            summary: null,
            status: SessionStatus.ready,
            similarity: 0.95,
          ),
        ], queryEmbedding: [0.1, 0.2]),
        embeddings: _FakeEmbeddings([
          const SemanticSearchResult(
            sessionId: 'local',
            title: 'Local hit',
            summary: null,
            status: SessionStatus.ready,
            similarity: 0.9,
          ),
          const SemanticSearchResult(
            sessionId: 'cloud',
            title: 'Cloud hit',
            summary: null,
            status: SessionStatus.ready,
            similarity: 0.95,
          ),
        ]),
      );

      final results = await repo.search('budget');
      expect(results.map((r) => r.sessionId), ['cloud', 'local']);
    });

    test('engine failure degrades to no results', () async {
      final repo = HybridSemanticSearchRepository(
        engine: _ThrowingEngineGateway(),
        embeddings: _FakeEmbeddings(const []),
      );
      expect(await repo.search('anything'), isEmpty);
    });

    test('no query embedding falls back to engine results only', () async {
      final repo = HybridSemanticSearchRepository(
        engine: _FakeEngineGateway([
          const SemanticSearchResult(
            sessionId: 's9',
            title: 'Engine only',
            summary: null,
            status: SessionStatus.ready,
            similarity: 0.8,
          ),
        ], queryEmbedding: const []),
        embeddings: _FakeEmbeddings(const []),
      );
      final results = await repo.search('x');
      expect(results.single.sessionId, 's9');
    });

    test('empty query short-circuits', () async {
      final repo = HybridSemanticSearchRepository(
        engine: _FakeEngineGateway(const []),
        embeddings: _FakeEmbeddings(const []),
      );
      expect(await repo.search('   '), isEmpty);
    });
  });
}

class _FakeEngineGateway implements EngineGateway {
  _FakeEngineGateway(this.results, {this.queryEmbedding = const [0.5]});

  final List<SemanticSearchResult> results;
  final List<double> queryEmbedding;

  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) async =>
      EngineSemanticSearch(
        results: results,
        queryEmbedding: queryEmbedding,
        dimension: queryEmbedding.length,
      );

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) =>
      throw UnimplementedError();

  @override
  Future<Job> getJob(String userId, String jobId) => throw UnimplementedError();

  @override
  Future<void> cancelJob(String userId, String jobId) =>
      throw UnimplementedError();

  @override
  Stream<Job> streamJob(String userId, String jobId) => const Stream.empty();

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) async =>
      EngineEmbedSessions(embeddings: const [], dimension: 0);

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) async => const [];

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
  Future<void> disconnectPlugin(String userId, String kind) async {}
}

class _ThrowingEngineGateway implements EngineGateway {
  @override
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  }) =>
      throw const EngineFailure('engine unreachable');

  @override
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  }) async =>
      EngineEmbedSessions(embeddings: const [], dimension: 0);

  @override
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  }) =>
      throw UnimplementedError();

  @override
  Future<Job> getJob(String userId, String jobId) => throw UnimplementedError();

  @override
  Future<void> cancelJob(String userId, String jobId) =>
      throw UnimplementedError();

  @override
  Stream<Job> streamJob(String userId, String jobId) => const Stream.empty();

  @override
  Future<List<PluginTargetStatus>> listPlugins(String userId) async => const [];

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
  Future<void> disconnectPlugin(String userId, String kind) async {}
}

class _FakeEmbeddings implements EmbeddingRepository {
  _FakeEmbeddings(this.results);

  final List<SemanticSearchResult> results;

  @override
  Future<List<SemanticSearchResult>> searchSimilar(
    List<double> queryVector, {
    int limit = 20,
    double threshold = 0.7,
    String? excludeSessionId,
  }) async =>
      results
          .where((r) => r.sessionId != excludeSessionId)
          .where((r) => r.similarity >= threshold)
          .take(limit)
          .toList();

  @override
  Future<void> upsertSessionEmbedding({
    required String sessionId,
    required String scope,
    required String contentRef,
    required List<double> vector,
  }) =>
      Future.value();

  @override
  Future<List<double>?> embeddingForSession(String sessionId) async => null;

  @override
  Future<List<String>> sessionsWithoutLocalEmbedding() async => const [];

  @override
  Future<void> deleteSessionEmbeddings(String sessionId) => Future.value();
}
