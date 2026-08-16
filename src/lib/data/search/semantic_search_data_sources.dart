import '../../domain/entities/semantic_search_result.dart';
import '../../domain/repositories.dart';

/// Hybrid semantic search (architecture §5.4, §6.1).
///
/// Retrieval is local-first: the engine embeds the query (the app never runs
/// models itself — all AI traffic goes through the engine, architecture §2),
/// and the returned query embedding ranks vectors already stored on-device in
/// drift. Engine-side pgvector results fill in sessions missing locally.
/// Results are merged, deduped by session id and sorted by similarity.
class HybridSemanticSearchRepository implements SemanticSearchRepository {
  HybridSemanticSearchRepository({
    required this.engine,
    required this.embeddings,
    this.threshold = 0.5,
  });

  final EngineGateway engine;
  final EmbeddingRepository embeddings;

  /// Minimum cosine similarity for both the local and cloud result sets.
  final double threshold;

  @override
  Future<List<SemanticSearchResult>> search(
    String query, {
    int limit = 20,
  }) async {
    if (query.trim().isEmpty) return const [];

    final EngineSemanticSearch engineSearch;
    try {
      engineSearch = await engine.semanticSearch(
        query,
        limit: limit,
        threshold: threshold,
      );
    } on AppFailure {
      // Engine unreachable: there is no way to embed the query on-device, so
      // semantic search degrades to "no results" rather than failing.
      return const [];
    }

    final queryVector = engineSearch.queryEmbedding;
    if (queryVector.isEmpty) {
      return engineSearch.results.take(limit).toList();
    }

    final local = await embeddings.searchSimilar(
      queryVector,
      limit: limit,
      threshold: threshold,
    );

    final merged = <String, SemanticSearchResult>{
      for (final r in local) r.sessionId: r,
      for (final r in engineSearch.results) r.sessionId: r,
    };
    final results = merged.values.toList()
      ..sort((a, b) => b.similarity.compareTo(a.similarity));
    return results.take(limit).toList();
  }
}
