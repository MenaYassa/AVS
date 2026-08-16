import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/semantic_search_result.dart';
import '../../domain/repositories.dart';

/// Semantic search mode state (architecture §6.1): keyword FTS or embedding
/// similarity. Kept in the provider so the screen survives rebuilds.
final semanticSearchModeProvider = StateProvider<SemanticSearchMode>(
  (ref) => SemanticSearchMode.keyword,
);

enum SemanticSearchMode { keyword, semantic }

/// Semantic search over embeddings via the engine (architecture §5.4, §6.1).
/// Debounced like the keyword search; previous results stay visible while
/// typing.
final semanticSearchControllerProvider =
    AsyncNotifierProvider<SemanticSearchController, List<SemanticSearchResult>>(
        SemanticSearchController.new);

class SemanticSearchController
    extends AsyncNotifier<List<SemanticSearchResult>> {
  Timer? _debounce;

  @override
  Future<List<SemanticSearchResult>> build() async {
    ref.onDispose(() {
      _debounce?.cancel();
      _debounce = null;
    });
    return const [];
  }

  void onQueryChanged(String raw) {
    _debounce?.cancel();
    final query = raw.trim();
    if (query.isEmpty) {
      state = const AsyncData([]);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _debounce = null;
      _run(query);
    });
  }

  Future<void> _run(String query) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(semanticSearchRepositoryProvider).search(query),
    );
  }
}
