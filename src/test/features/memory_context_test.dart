import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/graph.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/memory/memory_context.dart';
import 'package:ai_knowledge_companion/features/settings/intelligence_controller.dart';
import 'package:ai_knowledge_companion/features/settings/memory_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAppSettings implements AppSettingsRepository {
  final Map<String, bool> memory = {};
  final Map<String, bool> skip = {};

  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async => false;

  @override
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value) async {}

  @override
  Future<bool> getEnableInsights(String userId) async => false;

  @override
  Future<void> setEnableInsights(String userId, bool value) async {}

  @override
  Future<bool> getEnableMemory(String userId) async => memory[userId] ?? false;

  @override
  Future<void> setEnableMemory(String userId, bool value) async {
    memory[userId] = value;
  }

  @override
  Future<bool> getMemorySkip(String sessionId) async => skip[sessionId] ?? false;

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {
    skip[sessionId] = value;
  }
}

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
  late GraphLocalDataSource graph;
  late TagLocalDataSource tags;
  late _FakeAppSettings appSettings;

  Session draftSession(
    String id, {
    List<String> entityNames = const [],
    List<String> taskTitles = const [],
    SessionStatus status = SessionStatus.ready,
  }) =>
      Session(
        id: id,
        userId: 'u1',
        title: 'Session $id',
        summary: 'We discussed ${entityNames.join(' and ')}.',
        cleanedTranscript: 'Notes about ${entityNames.join(', ')}.',
        status: status,
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
              for (final title in taskTitles)
                Item(
                  id: 'i-$id-$title',
                  type: ItemType.task,
                  title: title,
                  description: '',
                  position: 0,
                ),
              Item(
                id: 'i-$id-idea',
                type: ItemType.idea,
                title: 'Idea ${entityNames.isNotEmpty ? entityNames.first : 'x'}',
                description: 'About nothing.',
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
    graph = GraphLocalDataSource(db);
    tags = TagLocalDataSource(db);
    appSettings = _FakeAppSettings();
  });

  tearDown(() => db.close());

  Future<void> insertAnalyzed(
    String id, {
    List<String> entityNames = const [],
    List<String> taskTitles = const [],
    List<String> tagNames = const [],
  }) async {
    final session = draftSession(id,
        entityNames: entityNames, taskTitles: taskTitles);
    await sessions.insertSession(session);
    await sessions.replaceTopics(id, session.topics);
    if (entityNames.isNotEmpty) {
      await graph.replaceSubgraph(
        id,
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

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        tagRepositoryProvider.overrideWithValue(tags),
        appSettingsRepositoryProvider.overrideWithValue(appSettings),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ]);

  /// Waits for the async intelligence-settings load, then resolves the memory
  /// block for [sessionId] as a job submission would.
  Future<List<Map<String, dynamic>>> readMemory(
    ProviderContainer container,
    String sessionId,
  ) async {
    await container.read(intelligenceSettingsProvider.future);
    final settings = container.read(intelligenceSettingsProvider).valueOrNull;
    return memoryForSession(
      enableMemory: settings?.enableMemory ?? false,
      readSkip: () => container.read(memorySkipProvider(sessionId).future),
      readSessions: () =>
          container.read(databaseProvider).watchSessions().first,
      tagsFor: (id) => container.read(tagRepositoryProvider).getTagsForSession(id),
      sessionId: sessionId,
    );
  }

  group('sessionToMemoryDescriptor', () {
    test('carries session id, title, summary and open tasks', () {
      final session = draftSession(
        's1',
        entityNames: ['Release'],
        taskTitles: ['Ship the export feature', 'Write tests'],
      );
      final descriptor = sessionToMemoryDescriptor(session);

      expect(descriptor['session_id'], 's1');
      expect(descriptor['title'], 'Session s1');
      expect(descriptor['summary'], contains('Release'));
      expect(descriptor['open_tasks'], [
        'Ship the export feature',
        'Write tests',
      ]);
    });

    test('action items count as open tasks, ideas do not', () {
      final session = Session(
        id: 's1',
        userId: 'u1',
        title: 'S',
        status: SessionStatus.ready,
        topics: [
          Topic(
            id: 't1',
            title: 'T',
            description: '',
            position: 0,
            items: [
              Item(
                id: 'a1',
                type: ItemType.actionItem,
                title: 'Follow up with team',
                position: 0,
              ),
              Item(
                id: 'a2',
                type: ItemType.reminder,
                title: 'Buy milk',
                position: 0,
              ),
            ],
          ),
        ],
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      final descriptor = sessionToMemoryDescriptor(session);
      expect(descriptor['open_tasks'], ['Follow up with team']);
    });
  });

  group('buildMemoryContext', () {
    test('ranks by shared tags then entities and excludes the current session',
        () async {
      final sessionsList = [
        draftSession('current', entityNames: ['Release', 'Auth']),
        draftSession('s1', entityNames: ['Release']), // 1 shared entity
        draftSession('s2', entityNames: ['Unrelated']),
        draftSession('s3', entityNames: ['Release', 'Auth']),
      ];
      Future<List<Tag>> tagsFor(String id) async => id == 's3'
          ? [Tag(id: 't3', userId: 'u1', name: 'planning')]
          : const [];

      final context = await buildMemoryContext(
        sessions: sessionsList,
        currentSessionId: 'current',
        tagsFor: tagsFor,
      );

      // s3 shares both entities (score 2), s1 shares one (score 1); s2 shares
      // nothing so it is excluded.
      expect(context.map((d) => d['session_id']), ['s3', 's1']);
    });

    test('excludes sessions that are not analyzed', () async {
      final sessionsList = [
        draftSession('current', entityNames: ['Release']),
        draftSession('recording', entityNames: ['Release'],
            status: SessionStatus.recording),
        draftSession('ready', entityNames: ['Release']),
      ];
      final context = await buildMemoryContext(
        sessions: sessionsList,
        currentSessionId: 'current',
        tagsFor: (_) async => const [],
      );
      expect(context.map((d) => d['session_id']), ['ready']);
    });

    test('caps at kMaxMemoryEntries', () async {
      final sessionsList = [
        draftSession('current', entityNames: ['Release']),
        for (var i = 0; i < 12; i++)
          draftSession('s$i', entityNames: ['Release']),
      ];
      final context = await buildMemoryContext(
        sessions: sessionsList,
        currentSessionId: 'current',
        tagsFor: (_) async => const [],
      );
      expect(context, hasLength(kMaxMemoryEntries));
    });

    test('returns empty when nothing is related', () async {
      final sessionsList = [
        draftSession('current', entityNames: ['Release']),
        draftSession('other', entityNames: ['Unrelated']),
      ];
      final context = await buildMemoryContext(
        sessions: sessionsList,
        currentSessionId: 'current',
        tagsFor: (_) async => const [],
      );
      expect(context, isEmpty);
    });

    test('every descriptor in a memory block is source-tagged (provenance)',
        () async {
      final sessionsList = [
        draftSession('current', entityNames: ['Release']),
        for (var i = 0; i < 5; i++)
          draftSession('s$i', entityNames: ['Release']),
      ];
      final context = await buildMemoryContext(
        sessions: sessionsList,
        currentSessionId: 'current',
        tagsFor: (_) async => const [],
      );
      expect(context, isNotEmpty);
      for (final descriptor in context) {
        final sessionId = descriptor['session_id'];
        expect(sessionId, isA<String>());
        expect((sessionId as String), isNotEmpty);
      }
    });
  });

  group('memoryForSession', () {
    test('is empty when AI memory is off (default)', () async {
      await insertAnalyzed('s1');
      final container = makeContainer();
      addTearDown(container.dispose);

      final context = await readMemory(container, 's0');
      expect(context, isEmpty);
    });

    test('is empty when the session opts out', () async {
      appSettings.memory['u1'] = true;
      appSettings.skip['s0'] = true;
      await insertAnalyzed('s1');
      final container = makeContainer();
      addTearDown(container.dispose);

      final context = await readMemory(container, 's0');
      expect(context, isEmpty);
    });

    test('ships related sessions that share a tag', () async {
      appSettings.memory['u1'] = true;
      await insertAnalyzed('s0', tagNames: ['planning']);
      await insertAnalyzed('s1', tagNames: ['planning']);
      await insertAnalyzed('s2');
      final container = makeContainer();
      addTearDown(container.dispose);

      final context = await readMemory(container, 's0');
      expect(context.map((d) => d['session_id']), ['s1']);
    });

    test('ships descriptors with open tasks for related sessions', () async {
      appSettings.memory['u1'] = true;
      await insertAnalyzed('s0', entityNames: ['Release']);
      await insertAnalyzed(
        's1',
        entityNames: ['Release'],
        taskTitles: ['Ship export'],
      );

      final container = makeContainer();
      addTearDown(container.dispose);

      final context = await readMemory(container, 's0');
      expect(context, hasLength(1));
      expect(context.single['session_id'], 's1');
      expect(context.single['open_tasks'], ['Ship export']);
    });
  });
}
