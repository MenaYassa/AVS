import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/search_result.dart';
import 'package:ai_knowledge_companion/domain/entities/semantic_search_result.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/search/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _hits = [
  SearchResult(
    sessionId: 's1',
    title: 'Treasure map',
    summary: 'The map points to \u0001treasure\u0002 island.',
    status: SessionStatus.ready,
    rank: 1,
    snippet: 'The map points to \u0001treasure\u0002 island.',
  ),
];

const _semanticHits = [
  SemanticSearchResult(
    sessionId: 's2',
    title: 'Budget recap',
    summary: 'Q3 numbers and next steps.',
    status: SessionStatus.ready,
    similarity: 0.92,
  ),
];

class _FakeSearchRepository implements SearchRepository {
  int calls = 0;

  @override
  Future<List<SearchResult>> search(String query) async {
    calls++;
    return _hits;
  }
}

class _FakeSemanticSearchRepository implements SemanticSearchRepository {
  int calls = 0;

  @override
  Future<List<SemanticSearchResult>> search(
    String query, {
    int limit = 20,
  }) async {
    calls++;
    return _semanticHits;
  }
}

Widget _app(
  _FakeSearchRepository repo, {
  _FakeSemanticSearchRepository? semantic,
}) {
  final router = GoRouter(
    initialLocation: '/search',
    routes: [
      GoRoute(path: '/search', builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: '/sessions/:id',
        builder: (_, state) => Scaffold(
          body: Text('detail:${state.pathParameters['id']}'),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      searchRepositoryProvider.overrideWithValue(repo),
      if (semantic != null)
        semanticSearchRepositoryProvider.overrideWithValue(semantic),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('typing searches after the debounce and shows highlighted hits',
      (tester) async {
    final repo = _FakeSearchRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.text('Type to search your knowledge'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'treasure');
    expect(repo.calls, 0); // debounced: no query yet
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(repo.calls, 1);
    expect(find.textContaining('Treasure map'), findsOneWidget);
    expect(find.textContaining('treasure', findRichText: true), findsWidgets);
  });

  testWidgets('clearing the field empties results without a query',
      (tester) async {
    final repo = _FakeSearchRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('Treasure map'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('Type to search your knowledge'), findsOneWidget);
  });

  testWidgets('tapping a result navigates to the session', (tester) async {
    final repo = _FakeSearchRepository();
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'treasure');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Treasure map'));
    await tester.pumpAndSettle();

    expect(find.text('detail:s1'), findsOneWidget);
  });

  testWidgets('semantic mode searches by similarity and shows percentages',
      (tester) async {
    final semantic = _FakeSemanticSearchRepository();
    await tester.pumpWidget(_app(_FakeSearchRepository(), semantic: semantic));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Semantic'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'budget numbers');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(semantic.calls, 1);
    expect(find.text('Budget recap'), findsOneWidget);
    expect(find.text('92%'), findsOneWidget);
  });
}
