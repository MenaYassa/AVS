import 'dart:convert';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/domain/usecases/save_draft_to_session.dart';
import 'package:ai_knowledge_companion/features/commands/command_bus_controller.dart';
import 'package:ai_knowledge_companion/features/editing/editing_controller.dart';
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

/// §5.6: the AI command bus is a draft producer — command output lands as an
/// editable draft and is never auto-applied into the session (architecture
/// §4.11, spec §23). The only path into the session is the explicit user save.
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late JobLocalDataSource jobs;
  late DraftLocalDataSource drafts;
  late EditLogLocalDataSource logs;
  late FakeEngineGateway engine;

  Session draftSession() => Session(
        id: 's1',
        userId: 'u1',
        title: 'Release planning',
        summary: 'We plan to ship v2.',
        cleanedTranscript: 'We plan to ship v2 by Friday.',
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
    drafts = DraftLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
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
        draftRepositoryProvider.overrideWithValue(drafts),
        tagRepositoryProvider.overrideWithValue(TagLocalDataSource(db)),
        editLogRepositoryProvider.overrideWithValue(logs),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ]);

  Future<void> flush() => pumpEventQueue();

  Future<void> insertReadySession() async {
    final session = draftSession();
    await sessions.insertSession(session);
    await sessions.replaceTopics(session.id, session.topics);
  }

  Future<Session> loadSession() async => (await sessions.getSession('s1'))!;

  /// Emits a successful `meeting_minutes` command result and flushes the bus.
  Future<void> completeMeetingMinutes() async {
    engine.emit(engine.created!.copyWith(
      status: JobStatus.running,
      stage: 'meeting_minutes',
      sessionStatus: 'ready',
      stageLabel: 'Writing minutes',
      updatedAt: DateTime.now().toUtc(),
    ));
    await flush();
    engine.emit(engine.created!.copyWith(
      status: JobStatus.succeeded,
      stage: null,
      sessionStatus: 'ready',
      stageLabel: null,
      resultJson: jsonEncode({
        'command': 'meeting_minutes',
        'session_id': 's1',
        'prompt_versions': {'meeting_minutes': 1},
        'draft': {
          'title': 'Minutes for Release planning',
          'body': 'Decided to ship v2 on Friday.',
          'items': [
            {'title': 'Ship v2', 'body': '', 'type': 'task', 'priority': 'high'},
            {'title': 'Send the summary', 'body': 'To the team', 'type': 'actionItem'},
          ],
        },
      }),
      updatedAt: DateTime.now().toUtc(),
    ));
    await flush();
  }

  test('succeeded command job creates an editable draft and never mutates the session',
      () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container
        .read(commandBusControllerProvider('s1').notifier)
        .runCommand('meeting_minutes');
    await flush();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.command);
    expect(engine.lastOptions!['command'], 'meeting_minutes');
    final context = engine.lastOptions!['context'] as Map<String, dynamic>;
    expect(context['session_id'], 's1');
    expect(context['title'], 'Release planning');

    await completeMeetingMinutes();

    final state = container.read(commandBusControllerProvider('s1'));
    expect(state.phase, CommandBusPhase.succeeded);
    expect(state.lastDraftId, isNotNull);

    // One draft was persisted, carrying the engine output + provenance.
    final draftsForSession = await drafts.watchDrafts('s1').first;
    expect(draftsForSession, hasLength(1));
    final draft = draftsForSession.single;
    expect(draft.id, state.lastDraftId);
    expect(draft.sessionId, 's1');
    expect(draft.command, 'meeting_minutes');
    expect(draft.title, 'Minutes for Release planning');
    expect(draft.body, 'Decided to ship v2 on Friday.');
    expect(draft.items.map((i) => i.title), ['Ship v2', 'Send the summary']);
    expect(draft.promptVersions, {'meeting_minutes': 1});

    // The session itself is untouched: no new topic, no item, no title change.
    final session = await loadSession();
    expect(session.topics, hasLength(1));
    expect(session.topics.single.title, 'Release plan');
    expect(session.topics.single.items.map((i) => i.title), ['Ship v2']);
    expect(session.title, 'Release planning');
  });

  test('command job failure produces no draft and leaves the session untouched',
      () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container
        .read(commandBusControllerProvider('s1').notifier)
        .runCommand('meeting_minutes');
    await flush();

    engine.emit(engine.created!.copyWith(
      status: JobStatus.failed,
      errorJson: '{"code":"JOB_FAILED","message":"llm unavailable"}',
      updatedAt: DateTime.now().toUtc(),
    ));
    await flush();

    final state = container.read(commandBusControllerProvider('s1'));
    expect(state.phase, CommandBusPhase.failed);
    expect(state.lastDraftId, isNull);
    expect(await drafts.watchDrafts('s1').first, isEmpty);

    final session = await loadSession();
    expect(session.topics, hasLength(1));
    expect(session.topics.single.title, 'Release plan');
  });

  test('a draft enters the session only through the explicit user save path',
      () async {
    await insertReadySession();
    final container = makeContainer();
    addTearDown(container.dispose);

    await container
        .read(commandBusControllerProvider('s1').notifier)
        .runCommand('meeting_minutes');
    await flush();
    await completeMeetingMinutes();

    final draft = (await drafts.watchDrafts('s1').first).single;
    final sessionBefore = await loadSession();
    expect(sessionBefore.topics, hasLength(1));

    // The exact path the Draft screen takes on "Save to session".
    final ops = buildSaveDraftOperations(sessionBefore, draft);
    expect(ops, isNotEmpty);
    expect(ops.whereType<AddTopic>(), isNotEmpty);
    final editing = container.read(editingControllerProvider('s1').notifier);
    for (final op in ops) {
      await editing.apply(op);
    }
    await drafts.deleteDraft(draft.id);
    await flush();

    // The session now carries the draft's content and the draft is consumed.
    final sessionAfter = await loadSession();
    expect(sessionAfter.topics, hasLength(2));
    final added = sessionAfter.topics
        .firstWhere((t) => t.title == draft.title);
    expect(added.items.map((i) => i.title), ['Ship v2', 'Send the summary']);
    expect(added.items.first.type, ItemType.task);
    expect(await drafts.watchDrafts('s1').first, isEmpty);
  });
}
