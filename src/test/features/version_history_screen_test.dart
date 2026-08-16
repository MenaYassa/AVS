import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/session_version.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/versioning/version_history_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// P3-C: the version-history picker renders commit points newest-first, shows
/// a per-version diff, and restores the working copy (architecture §4.6).
void main() {
  late AppDatabase db;
  late SessionLocalDataSource sessions;
  late VersionLocalDataSource versions;
  late EditLogLocalDataSource logs;

  final now = DateTime.now().toUtc();

  Session v1Session() => Session(
        id: 's1',
        userId: 'u1',
        title: 'Budget',
        summary: 'We reviewed the numbers.',
        status: SessionStatus.ready,
        createdAt: now,
        updatedAt: now,
        topics: const [
          Topic(id: 't1', position: 0, title: 'Budget', items: [
            Item(id: 'i1', type: ItemType.task, position: 0, title: 'A'),
          ]),
        ],
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    sessions = SessionLocalDataSource(db);
    versions = VersionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed({required int versionCount}) async {
    await sessions.insertSession(v1Session());
    await sessions.updateSession(v1Session());
    await versions.commit(SessionVersion(
      id: 'v1',
      sessionId: 's1',
      versionNo: 1,
      snapshot: v1Session(),
      changeReason: 'AI output',
      createdAt: now,
    ));
    if (versionCount > 1) {
      await versions.commit(SessionVersion(
        id: 'v2',
        sessionId: 's1',
        versionNo: 2,
        snapshot: v1Session().copyWith(title: 'Annual budget'),
        changeReason: 'Edited: changed 1 title',
        createdAt: now.add(const Duration(minutes: 5)),
      ));
    }
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(logs),
        versionRepositoryProvider.overrideWithValue(versions),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const VersionHistoryScreen(sessionId: 's1'),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('versions render newest-first with change reasons', (tester) async {
    await seed(versionCount: 2);
    await pumpHistory(tester);

    expect(find.text('Version history'), findsOneWidget);
    expect(find.text('AI output'), findsOneWidget);
    expect(find.text('Edited: changed 1 title'), findsOneWidget);

    // Newest first: v2 sits above v1.
    final v2Y = tester.getTopLeft(find.text('Edited: changed 1 title')).dy;
    final v1Y = tester.getTopLeft(find.text('AI output')).dy;
    expect(v2Y, lessThan(v1Y));
  });

  testWidgets('selecting a version shows its diff and the restore button',
      (tester) async {
    await seed(versionCount: 2);
    await pumpHistory(tester);

    // No selection yet: restore is disabled.
    final restore = find.widgetWithText(FilledButton, 'Select a version to restore');
    expect(restore, findsOneWidget);

    await tester.tap(find.text('Edited: changed 1 title'));
    await tester.pumpAndSettle();

    expect(find.text('What changed in v2'), findsOneWidget);
    expect(find.textContaining('Session title'), findsOneWidget);
    expect(find.text('Restore v2'), findsOneWidget);
  });

  testWidgets('the initial version shows no diff pane', (tester) async {
    await seed(versionCount: 1);
    await pumpHistory(tester);

    await tester.tap(find.text('AI output'));
    await tester.pumpAndSettle();

    expect(find.textContaining('initial version'), findsOneWidget);
  });

  testWidgets('restore replaces the working copy, saves a version, and pops',
      (tester) async {
    await seed(versionCount: 2);
    await pumpHistory(tester);

    await tester.tap(find.text('AI output'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore v1'));
    await tester.pumpAndSettle();

    expect(find.text('Restore v1?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    // Popped back to the launcher screen with the restore confirmation.
    expect(find.text('open'), findsOneWidget);
    expect(find.text('Restored v1 as a new version.'), findsOneWidget);

    final session = (await sessions.getSession('s1'))!;
    expect(session.title, 'Budget');
    expect(session.topics.single.title, 'Budget');

    final all = await versions.getVersions('s1');
    expect(all, hasLength(3));
    expect(all.last.changeReason, 'Restored from v1');
  });
}
