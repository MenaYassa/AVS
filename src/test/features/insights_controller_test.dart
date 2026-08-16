import 'dart:convert';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/insights/insights_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';

class _SignedInAuth implements AuthRepository {
  @override
  String? get currentUserId => 'u1';

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late JobLocalDataSource jobs;
  late GraphLocalDataSource graph;
  late TagLocalDataSource tags;
  late FakeEngineGateway engine;

  Session draftSession(String id, {required List<String> entityNames}) => Session(
        id: id,
        userId: 'u1',
        title: 'Session $id',
        summary: 'We discussed ${entityNames.join(' and ')}.',
        cleanedTranscript: 'Notes about ${entityNames.join(', ')}.',
        status: SessionStatus.ready,
        entities: [
          for (final name in entityNames)
            GraphEntity(
              id: 'e-$id-$name',
              userId: 'u1',
              type: EntityType.organization,
              name: name,
            ),
        ],
        topics: [
          Topic(
            id: 't-$id',
            title: 'Topic $id',
            description: '',
            position: 0,
            items: [
              Item(
                id: 'i-$id',
                type: ItemType.idea,
                title: 'Idea ${entityNames.first}',
                description: 'About ${entityNames.first}.',
                position: 0,
              ),
            ],
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    jobs = JobLocalDataSource(db);
    graph = GraphLocalDataSource(db);
    tags = TagLocalDataSource(db);
    engine = FakeEngineGateway();
  });

  tearDown(() async {
    engine.closeStream();
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        tagRepositoryProvider.overrideWithValue(tags),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ]);

  Future<void> flush() => pumpEventQueue();

  Future<void> insertAnalyzedSession(
    String id, {
    List<String> entityNames = const [],
    List<String> tagNames = const [],
  }) async {
    final session = draftSession(id, entityNames: entityNames);
    await sessions.insertSession(session);
    await sessions.replaceTopics(session.id, session.topics);
    if (entityNames.isNotEmpty) {
      await graph.replaceSubgraph(
        session.id,
        SessionGraph(
          entities: [
            for (final name in entityNames)
              GraphEntity(
                id: 'e-$id-$name',
                userId: 'u1',
                type: EntityType.organization,
                name: name,
              ),
          ],
          relationships: const [],
        ),
      );
    }
    for (final name in tagNames) {
      final tag = Tag(id: 'tag-$id-$name', userId: 'u1', name: name);
      await tags.save(tag);
      await tags.attachTag(sessionId: id, tagId: tag.id);
    }
  }

  group('sessionToInsightDescriptor', () {
    test('builds the compact descriptor shape', () {
      final session = draftSession('s1', entityNames: ['Benchmark']);
      final descriptor = sessionToInsightDescriptor(session, const [
        Tag(id: 't1', userId: 'u1', name: 'planning'),
      ]);

      expect(descriptor['session_id'], 's1');
      expect(descriptor['title'], 'Session s1');
      expect(descriptor['summary'], contains('Benchmark'));
      expect(descriptor['entities'], [
        {'name': 'Benchmark', 'type': 'organization'},
      ]);
      expect(descriptor['tags'], ['planning']);
      final items = descriptor['items'] as List<dynamic>;
      expect(items.single['title'], 'Idea Benchmark');
      expect(items.single['type'], 'idea');
    });

    test('caps the transcript', () {
      final long = List.filled(5000, 'a').join();
      final session = Session(
        id: 's1',
        userId: 'u1',
        status: SessionStatus.ready,
        originalTranscript: long,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      final descriptor = sessionToInsightDescriptor(session, const []);
      expect(
        (descriptor['transcript'] as String).length,
        kMaxDescriptorTranscriptChars,
      );
    });

    test('only analyzed sessions are candidates', () {
      expect(
        isAnalyzedForInsights(Session(
          id: 'a',
          userId: 'u1',
          status: SessionStatus.ready,
          createdAt: null,
          updatedAt: null,
        )),
        isTrue,
      );
      expect(
        isAnalyzedForInsights(Session(
          id: 'b',
          userId: 'u1',
          status: SessionStatus.recording,
          createdAt: null,
          updatedAt: null,
        )),
        isFalse,
      );
    });
  });

  group('InsightsController', () {
    test('refresh submits an insights job and streams the result', () async {
      await insertAnalyzedSession('s1', entityNames: ['Benchmark Platform']);
      await insertAnalyzedSession('s2', entityNames: ['benchmark platform']);
      final container = makeContainer();
      addTearDown(container.dispose);

      await container
          .read(insightsControllerProvider.notifier)
          .refresh();
      await flush();

      expect(engine.createCount, 1);
      expect(engine.created!.kind, JobKind.insights);
      final options = engine.lastOptions!;
      final sessions = options['sessions'] as List<dynamic>;
      expect(sessions, hasLength(2));
      expect(sessions.first['session_id'], isNotNull);

      expect(
        container.read(insightsControllerProvider).isRunning,
        isTrue,
      );

      engine.emit(engine.created!.copyWith(
        status: JobStatus.succeeded,
        resultJson: jsonEncode({
          'insights': [
            {
              'kind': 'entity',
              'label': 'Benchmark Platform',
              'session_count': 2,
              'mention_count': 2,
              'confidence': 0.5,
              'statement':
                  "You've discussed Benchmark Platform in 2 sessions.",
              'sources': [
                {
                  'session_id': 's1',
                  'title': 'Session s1',
                  'snippet': 'About Benchmark Platform.',
                },
                {
                  'session_id': 's2',
                  'title': 'Session s2',
                  'snippet': null,
                },
              ],
            },
          ],
          'generated_at': '2026-08-10T05:20:03+00:00',
          'total_sessions': 2,
        }),
        updatedAt: DateTime.now().toUtc(),
      ));
      await flush();

      final state = container.read(insightsControllerProvider);
      expect(state.phase, InsightsPhase.idle);
      final result = state.result!;
      expect(result.totalSessions, 2);
      expect(result.insights.single.statement,
          "You've discussed Benchmark Platform in 2 sessions.");
      final sources = result.insights.single.sources;
      expect(sources, hasLength(2));
      expect(sources.first.snippet, 'About Benchmark Platform.');
    });

    test('descriptors carry entities, tags, items and summaries', () async {
      await insertAnalyzedSession(
        's1',
        entityNames: ['Release'],
        tagNames: ['planning'],
      );
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(insightsControllerProvider.notifier).refresh();
      await flush();

      final sessions = engine.lastOptions!['sessions'] as List<dynamic>;
      final descriptor = sessions.single as Map<String, dynamic>;
      expect(descriptor['entities'], [
        {'name': 'Release', 'type': 'organization'},
      ]);
      expect(descriptor['tags'], ['planning']);
      final items = descriptor['items'] as List<dynamic>;
      expect(items.single['title'], 'Idea Release');
      expect(items.single['type'], 'idea');
      expect(descriptor['summary'], contains('Release'));
    });

    test('no analyzed sessions stays idle without submitting a job', () async {
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(insightsControllerProvider.notifier).refresh();
      await flush();

      expect(engine.createCount, 0);
      final state = container.read(insightsControllerProvider);
      expect(state.phase, InsightsPhase.idle);
      expect(state.result, isNull);
      expect(state.error, isNull);
    });

    test('job failure surfaces a structured error', () async {
      await insertAnalyzedSession('s1', entityNames: ['Benchmark Platform']);
      final container = makeContainer();
      addTearDown(container.dispose);

      await container.read(insightsControllerProvider.notifier).refresh();
      await flush();

      engine.emit(engine.created!.copyWith(
        status: JobStatus.failed,
        errorJson: '{"code":"INSIGHTS_CONTEXT_INVALID","message":"bad sessions"}',
        updatedAt: DateTime.now().toUtc(),
      ));
      await flush();

      final state = container.read(insightsControllerProvider);
      expect(state.phase, InsightsPhase.failed);
      expect(state.error, contains('bad sessions'));
    });
  });
}
