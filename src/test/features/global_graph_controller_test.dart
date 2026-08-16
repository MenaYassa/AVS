import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/graph/global_graph_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeGraphRepo implements GraphRepository {
  List<GraphEntity> entities = [];
  Map<String, List<String>> entityMemberships = {};

  @override
  Future<List<GraphEntity>> getEntities() async => entities;

  @override
  Future<List<String>> sessionIdsForEntity(String entityId) async =>
      entityMemberships[entityId] ?? const [];

  @override
  Future<List<GraphRelation>> getRelations() => throw UnimplementedError();

  @override
  Future<SessionGraph> getSubgraph(String sessionId) => throw UnimplementedError();

  @override
  Future<List<GraphEntity>> traverse(String rootId, {int maxDepth = 3}) => throw UnimplementedError();

  @override
  Future<void> saveEntity(GraphEntity entity) => throw UnimplementedError();

  @override
  Future<void> saveRelation(GraphRelation relation) => throw UnimplementedError();

  @override
  Future<void> replaceSubgraph(String sessionId, SessionGraph graph) => throw UnimplementedError();

  @override
  Future<void> deleteEntity(String id) => throw UnimplementedError();

  @override
  Future<void> deleteRelation(String id) => throw UnimplementedError();
}

class _FakeSessionRepo implements SessionRepository {
  final List<Session> sessions = [];

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(sessions);

  @override
  Future<Session?> getSession(String id) => throw UnimplementedError();

  @override
  Future<Session> insertSession(Session session) => throw UnimplementedError();

  @override
  Future<Session> updateSession(Session session, {bool emitDiff = true}) => throw UnimplementedError();

  @override
  Future<List<Topic>> getTopics(String sessionId) async => const [];

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {}

  @override
  Future<void> deleteSession(String id) => throw UnimplementedError();
}

void main() {
  late _FakeGraphRepo graphRepo;
  late _FakeSessionRepo sessionRepo;
  late ProviderContainer container;

  setUp(() {
    graphRepo = _FakeGraphRepo();
    sessionRepo = _FakeSessionRepo();
    container = ProviderContainer(
      overrides: [
        graphRepositoryProvider.overrideWithValue(graphRepo),
        databaseProvider.overrideWithValue(sessionRepo),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  test('build returns empty when there are no entities', () async {
    final state = await container.read(globalGraphControllerProvider.future);
    expect(state, isEmpty);
  });

  test('build maps entities, queries memberships, sorts by count and then name', () async {
    sessionRepo.sessions.addAll([
      const Session(id: 's1', userId: 'u1', title: 'Session One'),
      const Session(id: 's2', userId: 'u1', title: 'Session Two'),
    ]);

    graphRepo.entities = const [
      GraphEntity(id: 'e1', userId: 'u1', type: EntityType.person, name: 'Alice'),
      GraphEntity(id: 'e2', userId: 'u1', type: EntityType.concept, name: 'Zebra'),
      GraphEntity(id: 'e3', userId: 'u1', type: EntityType.concept, name: 'Apple'),
    ];

    graphRepo.entityMemberships = {
      'e1': ['s1', 's2'], // Alice: 2 sessions
      'e2': ['s1'],       // Zebra: 1 session
      'e3': ['s1'],       // Apple: 1 session
    };

    final state = await container.read(globalGraphControllerProvider.future);

    expect(state.length, 3);

    // Sorted by sessionCount (descending), then alphabetically (case-insensitive)
    expect(state[0].entity.name, 'Alice');
    expect(state[0].sessionCount, 2);
    expect(state[0].sessionTitles, ['Session One', 'Session Two']);

    expect(state[1].entity.name, 'Apple'); // Apple comes before Zebra
    expect(state[1].sessionCount, 1);
    expect(state[1].sessionTitles, ['Session One']);

    expect(state[2].entity.name, 'Zebra');
    expect(state[2].sessionCount, 1);
    expect(state[2].sessionTitles, ['Session One']);
  });
}
