import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/editing/editing_controller.dart';
import 'package:ai_knowledge_companion/features/versioning/version_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// P3-C: version history commit points and restore (architecture §4.6).
/// V1 snapshots the initial AI output; every edit batch appends a version;
/// restore makes the snapshot the working copy, records a "Restored from v{n}"
/// version, and clears the edit log so undo can't cross the restore boundary.
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late EditLogLocalDataSource logs;
  late VersionLocalDataSource versions;

  Session baseSession({SessionStatus status = SessionStatus.ready}) => Session(
        id: 's1',
        userId: 'u1',
        title: 'Budget',
        summary: 'We reviewed the numbers.',
        status: status,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        topics: const [
          Topic(id: 't1', position: 0, title: 'Budget', items: [
            Item(
                id: 'i1',
                type: ItemType.task,
                position: 0,
                title: 'A',
                confidence: 0.9),
          ]),
        ],
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
    versions = VersionLocalDataSource(db);
  });

  tearDown(() async {
    await db.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(logs),
        versionRepositoryProvider.overrideWithValue(versions),
      ]);

  /// Seeds a ready session. `insertSession` drops topics (test-infra fact), so
  /// topics go in via `updateSession`.
  Future<void> seedReady() async {
    await sessions.insertSession(baseSession());
    await sessions.updateSession(baseSession());
  }

  Future<void> flush() => pumpEventQueue();

  test('opening a ready session commits V1 (AI output) with no topic loss',
      () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    final state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(1));
    expect(state.versions.single.versionNo, 1);
    expect(state.versions.single.changeReason, 'AI output');
    expect(state.versions.single.snapshot.topics.single.title, 'Budget');

    final persisted = await versions.getVersions('s1');
    expect(persisted.single.versionNo, 1);
  });

  test('a session without content or not ready is not snapshotted', () async {
    await sessions.insertSession(baseSession(status: SessionStatus.recording));
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    expect(container.read(versioningControllerProvider('s1')).versions, isEmpty);
    expect(await versions.getVersions('s1'), isEmpty);
  });

  test('each committed edit batch appends a version with a change reason',
      () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    final edit = container.read(editingControllerProvider('s1').notifier);
    await edit.apply(const RenameTopic(
        topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));
    await flush();
    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitEditBatch();
    await flush();

    final state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(2));
    expect(state.versions.last.versionNo, 2);
    expect(state.versions.last.changeReason, contains('renamed 1 topic'));
    expect(state.versions.last.snapshot.topics.single.title, 'Finances');
  });

  test('no-op commitEditBatch does not create a version', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitEditBatch();
    await flush();

    final state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(1));
  });

  test('undo/redo do not create versions; the next edit does', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    final edit = container.read(editingControllerProvider('s1').notifier);
    await edit.apply(const RenameTopic(
        topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));
    await edit.undo();
    await flush();
    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitEditBatch();
    await flush();

    // Undo is not an edit batch: still just V1.
    var state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(1));

    await edit.apply(const UpdateSessionTitle(
        oldTitle: 'Budget', newTitle: 'Annual budget'));
    await flush();
    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitEditBatch();
    await flush();

    state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(2));
    expect(state.versions.last.changeReason, contains('changed 1 title'));
  });

  test('restore replaces content, appends a version, clears the edit log',
      () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    final edit = container.read(editingControllerProvider('s1').notifier);
    await edit.apply(const RenameTopic(
        topicId: 't1', oldTitle: 'Budget', newTitle: 'Finances'));
    await edit.apply(const UpdateItemText(
      topicId: 't1',
      itemId: 'i1',
      oldTitle: 'A',
      oldDescription: '',
      newTitle: 'Finalize the budget',
      newDescription: '',
      oldConfidence: 0.9,
    ));
    await flush();
    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitEditBatch();
    await flush();

    final restored =
        await container.read(versioningControllerProvider('s1').notifier).restore(1);
    expect(restored, isNotNull);
    await flush();

    final session = (await sessions.getSession('s1'))!;
    expect(session.topics.single.title, 'Budget');
    expect(session.topics.single.items.single.title, 'A');
    expect(session.topics.single.items.single.confidence, 0.9);

    final state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(3));
    expect(state.versions.last.changeReason, 'Restored from v1');
    expect(state.versions.last.versionNo, 3);

    // The edit log is cleared: undo must be a no-op after the restore.
    expect(container.read(editingControllerProvider('s1')).canUndo, isFalse);
    await edit.undo();
    await flush();
    expect((await sessions.getSession('s1'))!.topics.single.title, 'Budget');
  });

  test('versions and the log survive a restart (persisted in drift)', () async {
    await seedReady();
    final first = makeContainer();
    first.read(versioningControllerProvider('s1'));
    await flush();
    await first.read(versioningControllerProvider('s1').notifier).commitEditBatch();
    await flush();
    first.dispose();

    final second = makeContainer();
    addTearDown(second.dispose);
    second.read(versioningControllerProvider('s1'));
    await flush();

    final state = second.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(1));
    expect(state.versions.single.changeReason, 'AI output');
  });

  test('getVersion resolves a specific version number', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    final version = await versions.getVersion('s1', 1);
    expect(version, isNotNull);
    expect(version!.snapshot.title, 'Budget');
    expect(await versions.getVersion('s1', 99), isNull);
  });

  test('a prompt re-run that changes content appends a version', () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    // Simulate a re-analysis replacing content with new prompt versions.
    await sessions.updateSession(baseSession().copyWith(
          summary: 'Re-analyzed summary.',
          topics: const [Topic(id: 't2', position: 0, title: 'Risks')],
          promptVersions: const {'analysis': 'v2'},
        ));
    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitAnalysisResult();
    await flush();

    final state = container.read(versioningControllerProvider('s1'));
    expect(state.versions, hasLength(2));
    expect(state.versions.last.changeReason, 'Re-analyzed with new prompts');
    expect(state.versions.last.snapshot.summary, 'Re-analyzed summary.');
  });

  test('a re-analysis with identical content does not duplicate a version',
      () async {
    await seedReady();
    final container = makeContainer();
    addTearDown(container.dispose);
    container.read(versioningControllerProvider('s1'));
    await flush();

    await container
        .read(versioningControllerProvider('s1').notifier)
        .commitAnalysisResult();
    await flush();

    expect(
        container.read(versioningControllerProvider('s1')).versions,
        hasLength(1));
  });
}
