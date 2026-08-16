import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/graph_ids.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/graph/graph_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// P4-D: the knowledge graph screen renders the per-session subgraph and
/// drives every change through the op-log-backed [GraphController].
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late EditLogLocalDataSource logs;
  late GraphLocalDataSource graph;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
    graph = GraphLocalDataSource(db);
  });

  Future<void> seed({SessionGraph? sg}) async {
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Sync',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    if (sg != null) {
      await sessions.updateSession(Session(
        id: 's1',
        userId: 'u1',
        title: 'Sync',
        status: SessionStatus.ready,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        entities: sg.entities,
        relationships: sg.relationships,
      ));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(logs),
        graphRepositoryProvider.overrideWithValue(graph),
      ],
      child: const MaterialApp(home: GraphScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();
  }

  GraphEntity entity(String name) => GraphEntity(
        id: graphEntityId(name),
        userId: 'u1',
        type: name == 'Alice' ? EntityType.person : EntityType.project,
        name: name,
        confidence: 0.9,
      );

  testWidgets('empty graph shows the empty state', (tester) async {
    await seed();
    await pump(tester);

    expect(find.text('No entities yet.'), findsOneWidget);
    expect(find.text('No relationships yet.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('renders nodes + relationships from the persisted subgraph',
      (tester) async {
    final alice = entity('Alice');
    final bob = entity('Benchmark');
    await seed(sg: SessionGraph(
      entities: [alice, bob],
      relationships: [
        GraphRelation(
          id: 'e1',
          userId: 'u1',
          sourceId: alice.id,
          targetId: bob.id,
          type: RelationType.leads,
          sessionId: 's1',
          confidence: 0.7,
        ),
      ],
    ));
    await pump(tester);

    // Canvas node initials.
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    // Relationship list row.
    expect(find.text('Alice → Benchmark'), findsOneWidget);
    expect(find.textContaining('leads'), findsOneWidget);
    // AI confidence surfaced on the edge.
    expect(find.textContaining('70%'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('rename from the node sheet persists and clears confidence',
      (tester) async {
    final alice = entity('Alice');
    await seed(sg: SessionGraph(entities: [alice]));
    await pump(tester);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);

    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alicia');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.single.name, 'Alicia');
    expect(sg.entities.single.confidence, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('add entity via the app bar action', (tester) async {
    await seed();
    await pump(tester);

    await tester.tap(find.byIcon(Icons.add_box_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Website');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Type picker dialog.
    expect(find.text('Entity type'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.single.name, 'Website');
    expect(sg.entities.single.id, graphEntityId('Website'));

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });

  testWidgets('delete entity from the node sheet removes node + incident edges',
      (tester) async {
    final alice = entity('Alice');
    final bob = entity('Benchmark');
    await seed(sg: SessionGraph(
      entities: [alice, bob],
      relationships: [
        GraphRelation(
          id: 'e1',
          userId: 'u1',
          sourceId: alice.id,
          targetId: bob.id,
          type: RelationType.leads,
          sessionId: 's1',
        ),
      ],
    ));
    await pump(tester);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.single.name, 'Benchmark');
    expect(sg.relationships, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    await db.close();
  });
}
