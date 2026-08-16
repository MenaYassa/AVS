import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/semantic_search_result.dart';
import '../../domain/repositories.dart';

/// Related sessions for a session (§6.1 follow-up): nearest neighbors by
/// embedding similarity over the on-device index. Empty when the session has
/// no local embedding (e.g. predates the `embedding` stage and has not been
/// backfilled) or no neighbors clear the similarity threshold.
final relatedSessionsProvider = FutureProvider.autoDispose
    .family<List<SemanticSearchResult>, String>((ref, sessionId) async {
  final embeddings = ref.watch(embeddingRepositoryProvider);
  final vector = await embeddings.embeddingForSession(sessionId);
  if (vector == null || vector.isEmpty) return const [];
  return embeddings.searchSimilar(
    vector,
    limit: 5,
    threshold: 0.7,
    excludeSessionId: sessionId,
  );
});
