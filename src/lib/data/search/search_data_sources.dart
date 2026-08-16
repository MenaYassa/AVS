import '../../core/logging/app_logger.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/repositories.dart';

/// Search combining a live local FTS index with a cloud fallback
/// (architecture §5.4 "cloud-side FTS fallback when local index stale").
///
/// The schema v6 triggers keep the local index current, so this is the fast
/// path; when it misses (e.g. a fresh install whose cloud sessions have not
/// finished pulling), the remote index is queried as a fallback.
class FallbackSearchRepository implements SearchRepository {
  FallbackSearchRepository({required this.local, required this.remote});

  final SearchRepository local;
  final SearchRepository remote;

  @override
  Future<List<SearchResult>> search(String query) async {
    final localHits = await local.search(query);
    if (localHits.isNotEmpty) return localHits;
    try {
      return await remote.search(query);
    } catch (e, st) {
      Log.e('Cloud search fallback failed', e, st);
      return const [];
    }
  }
}

/// Search stub used in tests and local-only mode (no cloud backend).
class NoopSearchRepository implements SearchRepository {
  const NoopSearchRepository();

  @override
  Future<List<SearchResult>> search(String query) async => const [];
}
