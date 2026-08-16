import 'enums.dart';

/// A semantic search hit (architecture §5.4, §6.1). [similarity] is the cosine
/// similarity in [0, 1] between the query embedding and the session embedding.
class SemanticSearchResult {
  const SemanticSearchResult({
    required this.sessionId,
    required this.title,
    required this.summary,
    required this.status,
    required this.similarity,
  });

  final String sessionId;
  final String? title;
  final String? summary;
  final SessionStatus status;
  final double similarity;
}

/// The engine's `POST /api/v1/search/semantic` response (architecture §7.1).
/// [queryEmbedding] lets the app rank locally-stored vectors with the exact
/// embedding the engine used for the cloud search.
class EngineSemanticSearch {
  const EngineSemanticSearch({
    required this.results,
    required this.queryEmbedding,
    required this.dimension,
  });

  final List<SemanticSearchResult> results;
  final List<double> queryEmbedding;
  final int dimension;
}

/// One session's embedding from `POST /api/v1/search/embed_sessions` (§6.1
/// backfill): the vector the engine produced for the session's text, ready to
/// persist into the local index.
class EngineSessionEmbedding {
  const EngineSessionEmbedding({
    required this.sessionId,
    required this.embedding,
    required this.dimension,
  });

  final String sessionId;
  final List<double> embedding;
  final int dimension;
}

/// The engine's `POST /api/v1/search/embed_sessions` response.
class EngineEmbedSessions {
  const EngineEmbedSessions({required this.embeddings, required this.dimension});

  final List<EngineSessionEmbedding> embeddings;
  final int dimension;
}
