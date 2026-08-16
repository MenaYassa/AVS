import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/graph_ids.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/editing/editing_controller.dart';
import 'package:ai_knowledge_companion/features/graph/graph_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// P4-D: the knowledge graph controller drives the graph editor through the
/// single mutation path (the editing op-log). Every change persists, is
/// undoable, and round-trips through the local graph tables.
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late EditLogLocalDataSource logs;
  late GraphLocalDataSource graph;

  Session baseSession() => Session(
        id: 's1',
        userId: 'u1',
        title: 'Q3 planning',
        status: SessionStatus.ready,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

  GraphEntity entity(String name, {double? confidence}) => GraphEntity(
        id: graphEntityId(name),
        userId: 'u1',
        type: EntityType.project,
        name: name,
        confidence: confidence,
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
    graph = GraphLocalDataSource(db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(logs),
        graphRepositoryProvider.overrideWithValue(graph),
      ]);

  Future<void> flush() => pumpEventQueue();

  Future<void> seedSession() async {
    await sessions.insertSession(baseSession());
  }

  Future<void> seedGraph(SessionGraph sg) async {
    await sessions.updateSession(baseSession().copyWith(
          entities: sg.entities,
          relationships: sg.relationships,
        ));
  }

  test('addEntity persists with a deterministic id and casefold-dedupes',
      () async {
    await seedSession();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    await ctrl.addEntity(name: 'Website', type: EntityType.project);
    await flush();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities, hasLength(1));
    expect(sg.entities.single.id, graphEntityId('Website'));
    expect(sg.entities.single.type, EntityType.project);

    // Case-insensitive dedupe: adding the same name again is a no-op.
    await ctrl.addEntity(name: 'website', type: EntityType.idea);
    await flush();
    expect((await graph.getSubgraph('s1')).entities, hasLength(1));

    // The session round-trip carries the graph too.
    final session = (await sessions.getSession('s1'))!;
    expect(session.entities.single.name, 'Website');
  });

  test('renameEntity renames and clears AI confidence', () async {
    await seedSession();
    await seedGraph(SessionGraph(
      entities: [entity('Website', confidence: 0.9)],
    ));
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    final id = graphEntityId('Website');
    await ctrl.renameEntity(id, 'Web app');
    await flush();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.single.name, 'Web app');
    expect(sg.entities.single.confidence, isNull); // human edit clears §4.7
  });

  test('mergeEntities rewires incident edges and drops self-loops/duplicates',
      () async {
    final alice = entity('Alice');
    final bob = entity('Bob');
    final carol = entity('Carol');
    await seedSession();
    await seedGraph(SessionGraph(
      entities: [alice, bob, carol],
      relationships: [
        GraphRelation(
          id: graphRelationshipId(
              sessionId: 's1',
              sourceId: alice.id,
              targetId: bob.id,
              type: 'related_to'),
          userId: 'u1',
          sourceId: alice.id,
          targetId: bob.id,
          type: RelationType.relatedTo,
          sessionId: 's1',
        ),
        GraphRelation(
          id: graphRelationshipId(
              sessionId: 's1',
              sourceId: alice.id,
              targetId: carol.id,
              type: 'related_to'),
          userId: 'u1',
          sourceId: alice.id,
          targetId: carol.id,
          type: RelationType.relatedTo,
          sessionId: 's1',
        ),
      ],
    ));
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    await ctrl.mergeEntities(alice.id, bob.id);
    await flush();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.map((e) => e.name), isNot(contains('Alice')));
    expect(sg.entities.map((e) => e.name), containsAll(['Bob', 'Carol']));
    // Alice→Bob rewires into a Bob→Bob self-loop (dropped); Alice→Carol
    // rewires into Bob→Carol (survives).
    expect(sg.relationships, hasLength(1));
    expect(sg.relationships.single.sourceId, bob.id);
    expect(sg.relationships.single.targetId, carol.id);
    // Merge clears confidence on the surviving node (human edit).
    final bobNow = sg.entities.firstWhere((e) => e.id == bob.id);
    expect(bobNow.confidence, isNull);
  });

  test('deleteEntity removes the node and its incident edges', () async {
    final alice = entity('Alice');
    final bob = entity('Bob');
    await seedSession();
    await seedGraph(SessionGraph(
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
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    await ctrl.deleteEntity(alice.id);
    await flush();

    final sg = await graph.getSubgraph('s1');
    expect(sg.entities.single.name, 'Bob');
    expect(sg.relationships, isEmpty);
  });

  test('addRelationship skips missing endpoints; relabel + delete work',
      () async {
    final alice = entity('Alice');
    final bob = entity('Bob');
    await seedSession();
    await seedGraph(SessionGraph(entities: [alice, bob]));
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    // Missing endpoint: rejected.
    await ctrl.addRelationship(
      sourceId: alice.id,
      targetId: 'ghost',
      type: RelationType.leads,
    );
    await flush();
    expect((await graph.getSubgraph('s1')).relationships, isEmpty);

    await ctrl.addRelationship(
      sourceId: alice.id,
      targetId: bob.id,
      type: RelationType.leads,
    );
    await flush();
    var sg = await graph.getSubgraph('s1');
    expect(sg.relationships.single.type, RelationType.leads);
    expect(sg.relationships.single.id, graphRelationshipId(
      sessionId: 's1',
      sourceId: alice.id,
      targetId: bob.id,
      type: 'leads',
    ));

    await ctrl.relabelRelationship(
      sg.relationships.single.id,
      RelationType.discusses,
    );
    await flush();
    sg = await graph.getSubgraph('s1');
    expect(sg.relationships.single.type, RelationType.discusses);

    await ctrl.deleteRelationship(sg.relationships.single.id);
    await flush();
    expect((await graph.getSubgraph('s1')).relationships, isEmpty);
  });

  test('graph edits are undoable via the editing log', () async {
    await seedSession();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(graphControllerProvider('s1'));
    await flush();

    final ctrl = container.read(graphControllerProvider('s1').notifier);
    await ctrl.addEntity(name: 'Platform', type: EntityType.project);
    await flush();
    expect((await graph.getSubgraph('s1')).entities, hasLength(1));

    final editing = container.read(editingControllerProvider('s1').notifier);
    await editing.undo();
    await flush();
    expect((await graph.getSubgraph('s1')).entities, isEmpty);

    await editing.redo();
    await flush();
    expect((await graph.getSubgraph('s1')).entities.single.name, 'Platform');
  });
}
