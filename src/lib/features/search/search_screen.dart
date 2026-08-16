import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/entities/enums.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/entities/semantic_search_result.dart';
import 'embedding_backfill_controller.dart';
import 'search_controller.dart';
import 'semantic_search_controller.dart';

/// Global search screen (spec §19). Two modes (§6.1): keyword FTS over
/// titles/topics/items with matched-term highlighting, and semantic search by
/// embedding similarity (engine-embedded query ranked over local + cloud).
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    _focus.requestFocus();
    _controller.addListener(() {
      final mode = ref.read(semanticSearchModeProvider);
      if (mode == SemanticSearchMode.semantic) {
        ref
            .read(semanticSearchControllerProvider.notifier)
            .onQueryChanged(_controller.text);
      } else {
        ref
            .read(searchControllerProvider.notifier)
            .onQueryChanged(_controller.text);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onModeChanged(SemanticSearchMode mode) {
    ref.read(semanticSearchModeProvider.notifier).state = mode;
    // Reset both result lists so switching modes shows a clean slate.
    ref.read(searchControllerProvider.notifier).onQueryChanged(_controller.text);
    ref
        .read(semanticSearchControllerProvider.notifier)
        .onQueryChanged(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(semanticSearchModeProvider);
    final query = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Search sessions, topics, ideas…',
            border: InputBorder.none,
          ),
          onSubmitted: (value) => _onModeChanged(mode),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<SemanticSearchMode>(
                segments: const [
                  ButtonSegment(
                    value: SemanticSearchMode.keyword,
                    label: Text('Keyword'),
                    icon: Icon(Icons.search),
                  ),
                  ButtonSegment(
                    value: SemanticSearchMode.semantic,
                    label: Text('Semantic'),
                    icon: Icon(Icons.graphic_eq),
                  ),
                ],
                selected: {mode},
                onSelectionChanged: (selection) =>
                    _onModeChanged(selection.first),
              ),
            ),
          ),
          if (mode == SemanticSearchMode.semantic) _backfillBanner(),
          Expanded(
            child: mode == SemanticSearchMode.semantic
                ? _semanticResults(query)
                : _keywordResults(query),
          ),
        ],
      ),
    );
  }

  Widget _backfillBanner() {    final status = ref.watch(embeddingBackfillControllerProvider);
    return status.maybeWhen(
      data: (s) {
        if (s.complete && !s.inProgress) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                s.inProgress
                    ? Icons.hourglass_top
                    : Icons.data_object,
                size: 20,
                color: theme.colorScheme.onSecondaryContainer,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  s.inProgress
                      ? 'Embedding ${s.embedded}…'
                      : s.error != null
                          ? 'Backfill failed: ${s.error}'
                          : '${s.missing} session(s) predate semantic search. Embed them to enable related-content matching.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
              if (!s.inProgress && s.missing > 0) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => ref
                      .read(embeddingBackfillControllerProvider.notifier)
                      .backfill(),
                  child: const Text('Embed'),
                ),
              ],
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  Widget _keywordResults(String query) {
    final results = ref.watch(searchControllerProvider);
    return results.when(
      data: (hits) {
        if (hits.isEmpty) {
          return _EmptyHint(hasQuery: query.isNotEmpty);
        }
        return ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, i) => _SearchResultTile(hit: hits[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Search failed: $e')),
    );
  }

  Widget _semanticResults(String query) {
    final results = ref.watch(semanticSearchControllerProvider);
    return results.when(
      data: (hits) {
        if (hits.isEmpty) {
          return _EmptyHint(hasQuery: query.isNotEmpty);
        }
        return ListView.builder(
          itemCount: hits.length,
          itemBuilder: (context, i) => _SemanticResultTile(hit: hits[i]),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Semantic search failed: $e')),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.hasQuery});

  final bool hasQuery;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          hasQuery ? 'No matches' : 'Type to search your knowledge',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({required this.hit});

  final SearchResult hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = hit.title?.isNotEmpty == true ? hit.title! : 'Untitled session';
    final subtitle = hit.snippet ?? hit.summary;

    return ListTile(
      title: Text.rich(
        _highlight(title),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subtitle == null || subtitle.isEmpty
          ? null
          : Text.rich(
              _highlight(subtitle),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Text(
        _statusLabel(hit.status),
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      onTap: () => context.go('/sessions/${hit.sessionId}'),
    );
  }
}

class _SemanticResultTile extends StatelessWidget {
  const _SemanticResultTile({required this.hit});

  final SemanticSearchResult hit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = hit.title?.isNotEmpty == true ? hit.title! : 'Untitled session';
    final percent = (hit.similarity * 100).clamp(0, 100).toStringAsFixed(0);

    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        child: Text(
          '$percent%',
          style: theme.textTheme.labelSmall
              ?.copyWith(color: theme.colorScheme.onPrimary),
        ),
      ),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: hit.summary == null || hit.summary!.isEmpty
          ? null
          : Text(
              hit.summary!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Text(
        _statusLabel(hit.status),
        style: theme.textTheme.labelSmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      onTap: () => context.go('/sessions/${hit.sessionId}'),
    );
  }
}

/// Splits a snippet on the `\x01`/`\x02` markers the FTS index inserts around
/// matches, rendering the matched spans emphasized.
TextSpan _highlight(String text) {
  final spans = <InlineSpan>[];
  final start = '\u0001';
  final end = '\u0002';
  final buffer = StringBuffer();
  var inMatch = false;

  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    if (char == start) {
      if (buffer.isNotEmpty) {
        spans.add(TextSpan(text: buffer.toString()));
        buffer.clear();
      }
      inMatch = true;
    } else if (char == end) {
      if (buffer.isNotEmpty) {
        spans.add(TextSpan(
          text: buffer.toString(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
        buffer.clear();
      }
      inMatch = false;
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) {
    spans.add(TextSpan(
      text: buffer.toString(),
      style: inMatch ? const TextStyle(fontWeight: FontWeight.bold) : null,
    ));
  }
  return TextSpan(children: spans);
}

String _statusLabel(SessionStatus status) {
  if (status == SessionStatus.ready || status == SessionStatus.edited) {
    return '';
  }
  return status.name;
}
