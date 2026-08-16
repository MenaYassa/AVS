import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/search_result.dart';
import '../../domain/repositories.dart';

/// Search query state, debounced in [SearchController.onQueryChanged].
final searchQueryProvider = StateProvider<String>((ref) => '');

/// Global search over sessions/topics/items via the local FTS index with a
/// cloud fallback (architecture §4.1, §5.3–5.4). Query state lives in the
/// controller so a debounced re-search keeps the previous results visible
/// while typing instead of flashing a loading spinner.
final searchControllerProvider = AsyncNotifierProvider<SearchController,
    List<SearchResult>>(SearchController.new);

class SearchController extends AsyncNotifier<List<SearchResult>> {
  Timer? _debounce;

  @override
  Future<List<SearchResult>> build() async {
    ref.onDispose(() {
      _debounce?.cancel();
      _debounce = null;
    });
    return const [];
  }

  /// Entry point for the search field. Debounces so a fast typist triggers a
  /// single query once typing pauses.
  void onQueryChanged(String raw) {
    _debounce?.cancel();
    final query = raw.trim();
    if (query.isEmpty) {
      state = const AsyncData([]);
      ref.read(searchQueryProvider.notifier).state = '';
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _debounce = null;
      ref.read(searchQueryProvider.notifier).state = query;
      _run(query);
    });
  }

  Future<void> _run(String query) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(searchRepositoryProvider).search(query),
    );
  }
}
