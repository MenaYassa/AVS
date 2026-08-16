import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/semantic_search_result.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/session_detail/related_sessions_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEmbeddingRepo implements EmbeddingRepository {
  final Map<String, List<double>> embeddings = {};
  final List<SemanticSearchResult> searchResults = [];

  @override
  Future<List<double>?> embeddingForSession(String sessionId) async {
    return embeddings[sessionId];
  }

  @override
  Future<List<SemanticSearchResult>> searchSimilar(
    List<double> queryVector, {
    int limit = 20,
    double threshold = 0.7,
    String? excludeSessionId,
  }) async {
    return [
      for (final r in searchResults)
        if (r.sessionId != excludeSessionId && r.similarity >= threshold)
          r,
    ].take(limit).toList();
  }

  @override
  Future<List<String>> sessionsWithoutLocalEmbedding() => throw UnimplementedError();

  @override
  Future<void> upsertSessionEmbedding({
    required String sessionId,
    required String scope,
    required String contentRef,
    required List<double> vector,
  }) => throw UnimplementedError();

  @override
  Future<void> deleteSessionEmbeddings(String sessionId) => throw UnimplementedError();
}

void main() {
  late _FakeEmbeddingRepo embeddings;
  late ProviderContainer container;

  setUp(() {
    embeddings = _FakeEmbeddingRepo();
    container = ProviderContainer(
      overrides: [
        embeddingRepositoryProvider.overrideWithValue(embeddings),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('returns empty if the session has no embedding', () async {
    final results = await container.read(relatedSessionsProvider('s1').future);
    expect(results, isEmpty);
  });

  test('calls searchSimilar and filters results correctly', () async {
    embeddings.embeddings['s1'] = [0.1, 0.2];
    embeddings.searchResults.addAll([
      const SemanticSearchResult(
        sessionId: 's2',
        title: 'Session Two',
        summary: 'Summary two',
        status: SessionStatus.ready,
        similarity: 0.85,
      ),
      const SemanticSearchResult(
        sessionId: 's3',
        title: 'Session Three',
        summary: 'Summary three',
        status: SessionStatus.ready,
        similarity: 0.60, // Below default 0.7 threshold
      ),
      const SemanticSearchResult(
        sessionId: 's1', // Excluded (self)
        title: 'Session One',
        summary: 'Summary one',
        status: SessionStatus.ready,
        similarity: 0.99,
      ),
    ]);

    final results = await container.read(relatedSessionsProvider('s1').future);

    expect(results.length, 1);
    expect(results.first.sessionId, 's2');
    expect(results.first.similarity, 0.85);
  });
}
