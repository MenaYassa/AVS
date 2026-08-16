import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/editing/editing_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// P3-B: the [EditingController] is the single mutation path (architecture
/// §3.4). Every edit persists both the session and the op-log through the real
/// drift stack, so undo/redo survive restarts and bit-exact restore works end
/// to end (P3-A invariants wired through the repository seam).
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late EditLogLocalDataSource logs;

  Session readySession() => Session(
        id: 's1',
        userId: 'u1',
        title: 'Budget',
        summary: 'We reviewed the numbers.',
        status: SessionStatus.ready,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        topics: const [
          Topic(
            id: 't1',
            position: 0,
            title: 'Budget',
            items: [
              Item(
                id: 'i1',
                type: ItemType.task,
                position: 0,
                title: 'A',
                confidence: 0.9,
              ),
            ],
          ),
        ],
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(logs),
      ]);

  /// Seeds a ready session. `insertSession` drops topics (test-infra fact), so
  /// topics go in via `updateSession`.
  Future<void> seedReady() async {
    await sessions.insertSession(readySession());
    await sessions.updateSession(
      readySession().copyWith(
        topics: const [
          Topic(
            id: 't1',
            position: 0,
            title: 'Budget',
            items: [
              Item(
                id: 'i1',
                type: ItemType.task,
                position: 0,
                title: 'A',
                confidence: 0.9,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> flush() => pumpEventQueue();

  test('apply persists the edit + op-log and bumps the revision', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(editingControllerProvider('s1'));
    await flush();

    final ctrl = container.read(editingControllerProvider('s1').notifier);
    await ctrl.apply(const RenameTopic(
      topicId: 't1',
      oldTitle: 'Budget',
      newTitle: 'Finances',
    ));
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.topics.single.title, 'Finances');
    final persisted = await logs.getLog('s1');
    expect(persisted, isNotNull);
    expect(persisted!.canUndo, isTrue);
    final state = container.read(editingControllerProvider('s1'));
    expect(state.revision, 1);
    expect(state.canUndo, isTrue);
    expect(state.canRedo, isFalse);
    expect(state.hasError, isFalse);
  });

  test('undo restores the prior state and redo re-applies it', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(editingControllerProvider('s1'));
    await flush();

    final ctrl = container.read(editingControllerProvider('s1').notifier);
    await ctrl.apply(const RenameTopic(
      topicId: 't1',
      oldTitle: 'Budget',
      newTitle: 'Finances',
    ));
    await ctrl.undo();
    await flush();

    var session = (await sessions.getSession('s1'))!;
    expect(session.topics.single.title, 'Budget');
    var state = container.read(editingControllerProvider('s1'));
    expect(state.canUndo, isFalse);
    expect(state.canRedo, isTrue);

    await ctrl.redo();
    await flush();
    session = (await sessions.getSession('s1'))!;
    expect(session.topics.single.title, 'Finances');
    state = container.read(editingControllerProvider('s1'));
    expect(state.canUndo, isTrue);
    expect(state.canRedo, isFalse);
    expect(state.revision, 3);
  });

  test('content edits clear confidence; undo restores it bit-exactly', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(editingControllerProvider('s1'));
    await flush();
    final originalJson =
        (await sessions.getSession('s1'))!.toCanonicalJson();

    final ctrl = container.read(editingControllerProvider('s1').notifier);
    await ctrl.apply(const UpdateItemText(
      topicId: 't1',
      itemId: 'i1',
      oldTitle: 'A',
      oldDescription: '',
      newTitle: 'Finalize the budget',
      newDescription: 'Due Friday',
      oldConfidence: 0.9,
    ));
    await flush();

    var item = (await sessions.getSession('s1'))!
        .topics
        .single
        .items
        .single;
    expect(item.title, 'Finalize the budget');
    expect(item.confidence, isNull);

    await ctrl.undo();
    await flush();
    final restored = (await sessions.getSession('s1'))!;
    expect(restored.toCanonicalJson(), originalJson);
    item = restored.topics.single.items.single;
    expect(item.title, 'A');
    expect(item.confidence, 0.9);
  });

  test('the op-log survives a restart (persisted in drift)', () async {
    await seedReady();
    final first = makeContainer();
    first.read(editingControllerProvider('s1'));
    await flush();
    await first.read(editingControllerProvider('s1').notifier).apply(
        const RenameTopic(
            topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));
    await flush();
    first.dispose();

    final second = makeContainer();
    addTearDown(second.dispose);
    second.read(editingControllerProvider('s1'));
    await flush();

    final state = second.read(editingControllerProvider('s1'));
    expect(state.canUndo, isTrue);
    await second.read(editingControllerProvider('s1').notifier).undo();
    await flush();
    expect((await sessions.getSession('s1'))!.topics.single.title, 'Budget');
  });

  test('apply on a missing session is a no-op', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(editingControllerProvider('nope'));
    await flush();

    await container.read(editingControllerProvider('nope').notifier).apply(
        const RenameTopic(
            topicId: 't1', oldTitle: 'x', newTitle: 'y'));
    await flush();

    final state = container.read(editingControllerProvider('nope'));
    expect(state.revision, 0);
    expect(state.busy, isFalse);
    expect(state.hasError, isFalse);
  });

  test('resetLog clears undo/redo state', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(editingControllerProvider('s1'));
    await flush();
    final ctrl = container.read(editingControllerProvider('s1').notifier);

    await ctrl.apply(const RenameTopic(
        topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));
    await ctrl.resetLog();
    await flush();

    final state = container.read(editingControllerProvider('s1'));
    expect(state.canUndo, isFalse);
    expect(state.canRedo, isFalse);
    final persisted = await logs.getLog('s1');
    expect(persisted!.canUndo, isFalse);
  });
}
