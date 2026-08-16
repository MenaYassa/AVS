import 'dart:convert';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/chat/chat_controller.dart';
import 'package:ai_knowledge_companion/features/settings/intelligence_controller.dart';
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

void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late JobLocalDataSource jobs;
  late ChatLocalDataSource chat;
  late FakeEngineGateway engine;
  late _FakeAppSettings appSettings;

  Session draft() => Session(
        id: 's1',
        userId: 'u1',
        title: 'Release planning',
        summary: 'We plan to ship v2 by Friday.',
        cleanedTranscript: 'Hello world. We should ship v2 by Friday.',
        status: SessionStatus.ready,
        topics: [
          Topic(
            id: 't1',
            title: 'Release plan',
            description: 'v2 deadline',
            position: 0,
            items: [
              Item(
                id: 'i1',
                type: ItemType.task,
                title: 'Ship v2',
                description: 'Friday',
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
    chat = ChatLocalDataSource(db);
    engine = FakeEngineGateway();
    appSettings = _FakeAppSettings();
  });

  tearDown(() async {
    engine.closeStream();
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        chatRepositoryProvider.overrideWithValue(chat),
        tagRepositoryProvider.overrideWithValue(TagLocalDataSource(db)),
        appSettingsRepositoryProvider.overrideWithValue(appSettings),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ]);

  Future<void> flush() => pumpEventQueue();

  Future<void> insertReadySession() async {
    final session = draft();
    await sessions.insertSession(session);
    await sessions.replaceTopics(session.id, session.topics);
  }

  test('ask persists the question, submits a chat job, and saves the answer',
      () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(chatControllerProvider('s1').notifier).ask(
        'What tasks are still open?');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.chat);
    expect(engine.lastOptions!['question'], 'What tasks are still open?');
    final context = engine.lastOptions!['context'] as Map<String, dynamic>;
    expect(context['session_id'], 's1');
    expect(context['title'], 'Release planning');
    expect(context['topics'], isNotEmpty);

    // The user message is persisted before the job runs.
    var messages = await chat.watchMessages('s1').first;
    expect(messages, hasLength(1));
    expect(messages.single.isUser, isTrue);
    expect(messages.single.content, 'What tasks are still open?');

    final state = container.read(chatControllerProvider('s1'));
    expect(state.isRunning, isTrue);

    engine.emit(runningJob(engine.created!, 'chat', 'running', 'Chatting'));
    await flush();

    engine.emit(engine.created!.copyWith(
      status: JobStatus.succeeded,
      resultJson: jsonEncode({
        'question': 'What tasks are still open?',
        'session_id': 's1',
        'prompt_versions': {'chat': 1},
        'response': {
          'answer': 'Ship v2 by Friday.',
          'citations': ['[summary] Release planning', '[topic: "Release plan"]'],
          'confidence': 0.92,
        },
      }),
      updatedAt: DateTime.now().toUtc(),
    ));
    await flush();

    messages = await chat.watchMessages('s1').first;
    expect(messages, hasLength(2));
    final answer = messages.last;
    expect(answer.isUser, isFalse);
    expect(answer.content, 'Ship v2 by Friday.');
    expect(answer.citations, contains('[summary] Release planning'));
    expect(answer.confidence, 0.92);
    expect(answer.promptVersions, {'chat': 1});

    final after = container.read(chatControllerProvider('s1'));
    expect(after.phase, ChatPhase.idle);
  });

  test('empty questions are ignored', () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    final notifier = container.read(chatControllerProvider('s1').notifier);
    await notifier.ask('   ');
    await flush();

    expect(engine.createCount, 0);
    expect(await chat.watchMessages('s1').first, isEmpty);
  });

  test('job failure surfaces a structured error and keeps the question', () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(chatControllerProvider('s1').notifier).ask('What did I decide?');
    await flush();

    engine.emit(engine.created!.copyWith(
      status: JobStatus.failed,
      errorJson: '{"code":"STAGE_OUTPUT_INVALID","message":"chat: bad response"}',
      updatedAt: DateTime.now().toUtc(),
    ));
    await flush();

    final state = container.read(chatControllerProvider('s1'));
    expect(state.phase, ChatPhase.failed);
    expect(state.error, contains('chat: bad response'));

    // The user question is still in the history so the exchange is recoverable.
    final messages = await chat.watchMessages('s1').first;
    expect(messages.single.isUser, isTrue);
  });

  test('missing session fails without submitting a job', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(chatControllerProvider('s1').notifier).ask('Hello?');
    await flush();

    expect(engine.createCount, 0);
    final state = container.read(chatControllerProvider('s1'));
    expect(state.phase, ChatPhase.failed);
    expect(state.error, 'Session not found.');
  });

  test('chat context includes canonical topics and items', () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container.read(chatControllerProvider('s1').notifier).ask('Summarize');
    await flush();

    final context = engine.lastOptions!['context'] as Map<String, dynamic>;
    final topics = context['topics'] as List<dynamic>;
    expect(topics.single['title'], 'Release plan');
    final items = topics.single['items'] as List<dynamic>;
    expect(items.single['type'], 'task');
    expect(context['entities'], isEmpty);
  });

  // §5.6 memory provenance: when AI memory is on and a related session exists,
  // the chat job ships source-tagged descriptors and the answer keeps its
  // citations (architecture §4.9 — every memory-backed answer stays traceable).
  group('memory provenance', () {
    Session related(String id) => Session(
          id: id,
          userId: 'u1',
          title: 'Benchmark kickoff',
          summary: 'We set up the benchmark harness.',
          cleanedTranscript: 'We set up the benchmark harness.',
          status: SessionStatus.ready,
          topics: [
            Topic(
              id: 't-$id',
              title: 'Benchmark',
              description: '',
              position: 0,
              items: [
                Item(
                  id: 'i-$id',
                  type: ItemType.task,
                  title: 'Write the harness',
                  position: 0,
                ),
              ],
            ),
          ],
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        );

    Future<void> tagSession(String id, String tagName) async {
      final tags = TagLocalDataSource(db);
      final tag = Tag(id: 'tag-$id-$tagName', userId: 'u1', name: tagName);
      await tags.save(tag);
      await tags.attachTag(sessionId: id, tagId: tag.id);
    }

    Future<void> insertWithTag(String id, String tagName) async {
      final session = related(id);
      await sessions.insertSession(session);
      await sessions.replaceTopics(session.id, session.topics);
      await tagSession(id, tagName);
    }

    Future<void> enableMemory(ProviderContainer c) async {
      appSettings.memory['u1'] = true;
      await c.read(intelligenceSettingsProvider.future);
    }

    test('ships source-tagged memory descriptors and surfaces memorySources',
        () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      await insertReadySession();
      await tagSession('s1', 'planning');
      await insertWithTag('s2', 'planning');
      await enableMemory(container);

      await container.read(chatControllerProvider('s1').notifier).ask('What is the harness status?');
      await flush();

      final memory = engine.lastOptions!['memory'] as List<dynamic>;
      expect(memory, hasLength(1));
      final descriptor = memory.single as Map<String, dynamic>;
      expect(descriptor['session_id'], 's2');
      expect(descriptor['title'], 'Benchmark kickoff');
      expect(descriptor['summary'], contains('harness'));
      expect(descriptor['open_tasks'], ['Write the harness']);

      // Provenance surfaced to the UI: the controller records what rode in.
      final state = container.read(chatControllerProvider('s1'));
      expect(state.memorySources.map((d) => d['session_id']), ['s2']);

      // The answer persists its citations, including the memory source.
      engine.emit(engine.created!.copyWith(
        status: JobStatus.succeeded,
        resultJson: jsonEncode({
          'question': 'What is the harness status?',
          'session_id': 's1',
          'prompt_versions': {'chat': 2},
          'response': {
            'answer': 'The harness is being set up.',
            'citations': [
              '[summary] Release planning',
              '[memory: "Benchmark kickoff"]',
            ],
            'confidence': 0.7,
          },
        }),
        updatedAt: DateTime.now().toUtc(),
      ));
      await flush();

      final messages = await chat.watchMessages('s1').first;
      expect(messages, hasLength(2));
      expect(messages.last.citations, contains('[memory: "Benchmark kickoff"]'));
    });

    test('ships no memory when AI memory is off (default)', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      await insertReadySession();
      await tagSession('s1', 'planning');
      await insertWithTag('s2', 'planning');
      await container.read(intelligenceSettingsProvider.future);

      await container.read(chatControllerProvider('s1').notifier).ask('Any tasks?');
      await flush();

      expect(engine.lastOptions!['memory'], isEmpty);
      final state = container.read(chatControllerProvider('s1'));
      expect(state.memorySources, isEmpty);
    });

    test('ships no memory when the session opts out', () async {
      final container = makeContainer();
      addTearDown(container.dispose);
      await insertReadySession();
      await tagSession('s1', 'planning');
      await insertWithTag('s2', 'planning');
      appSettings.skip['s1'] = true;
      await enableMemory(container);

      await container.read(chatControllerProvider('s1').notifier).ask('Any tasks?');
      await flush();

      expect(engine.lastOptions!['memory'], isEmpty);
    });
  });
}
