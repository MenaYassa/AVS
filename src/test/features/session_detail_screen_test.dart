import 'dart:io';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/sync/sync_engine.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/playback/playback_controller.dart';
import 'package:ai_knowledge_companion/features/session_detail/session_detail_screen.dart';
import 'package:ai_knowledge_companion/features/sync/sync_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';
import '../helpers/playback_fakes.dart';

class _SignedInAuth implements AuthRepository {
  _SignedInAuth(this.userId);

  final String userId;

  @override
  String? get currentUserId => userId;

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

class _CloudRemote implements SyncRepository {
  _CloudRemote(this.session);

  _CloudRemote.empty() : session = null;

  final Session? session;

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async {
    return session == null ? const [] : [session!];
  }

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async {
    final s = session;
    return (s != null && s.id == sessionId) ? s : null;
  }

  @override
  Future<void> pushSession(Session session) async {}

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {}

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {}

  @override
  Future<void> pushTag(Tag tag) async {}

  @override
  Future<void> deleteTag({
    required String userId,
    required String tagId,
  }) async {}

  @override
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  }) async {}

  @override
  Future<List<Tag>> pullTags(String userId) async => const [];

  @override
  Future<List<SessionTag>> pullSessionTags(String userId) async => const [];
}

void main() {
  testWidgets('detail converges: cloud session appears after a sync pass',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final remote = _CloudRemote(Session(
      id: 's1',
      userId: 'u1',
      title: 'From the cloud',
      status: SessionStatus.ready,
      updatedAt: DateTime.utc(2026, 8, 6, 16),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(SessionLocalDataSource(db)),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(SyncEngine(db: db, remote: remote)),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('From the cloud'), findsOneWidget);
    expect(find.text('Status: ready'), findsOneWidget);
  });

  testWidgets('detail shows org actions, metadata, and attached tags (§4.2)',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    final sessions = SessionLocalDataSource(db);
    final tags = TagLocalDataSource(db);
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Tagged',
      status: SessionStatus.ready,
      durationSec: 30,
      wordCount: 12,
      language: 'en',
      favorite: true,
      pinned: true,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    ));
    await tags.save(const Tag(id: 'tag1', userId: 'u1', name: 'ideas', color: '#FF0000'));
    await tags.attachTag(sessionId: 's1', tagId: 'tag1');

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        tagRepositoryProvider.overrideWithValue(tags),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Tagged'), findsOneWidget);
    // AppBar org actions reflect the pinned + starred state.
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    // Metadata row (date, duration, words, language).
    expect(find.text('0m 30s'), findsOneWidget);
    expect(find.text('12 words'), findsOneWidget);
    expect(find.text('en'), findsOneWidget);
    // Tag chip from the session_tags join.
    expect(find.text('ideas'), findsOneWidget);

    // Drift `.watch()` streams keep a short-lived cache Timer; dispose the
    // tree, fire that timer, then close the DB before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    await db.close();
  });

  testWidgets('draft with audio shows Analyze, streams progress, then topics',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final jobs = JobLocalDataSource(db);
    final engine = FakeEngineGateway();
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Draft',
      status: SessionStatus.ready,
      audioPath: '/tmp/s1.m4a',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncProvider.overrideWithValue(_CloudRemote.empty()),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Not analyzed yet'), findsOneWidget);
    expect(find.text('Analyze'), findsOneWidget);

    await tester.tap(find.text('Analyze'));
    await tester.pump();
    await tester.pump();

    expect(engine.createCount, 1);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    engine.emit(
        runningJob(engine.created!, 'cleanup', 'cleaning', 'Cleaning up'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Cleaning up'), findsOneWidget);
    expect(find.text('Status: cleaning'), findsOneWidget);

    engine.emit(succeededJob(
        engine.created!,
        '{"schema_version":1,"session":{"id":"s1","title":"Q3 Budget",'
            '"status":"ready","prompt_versions":{},"topics":['
            '{"id":"t1","position":0,"title":"Budget","description":"","items":'
            '[{"id":"i1","type":"task","position":0,"title":"Finalize the budget",'
            '"description":""}]}]}}'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Q3 Budget'), findsOneWidget);
    await tester.tap(find.text('Budget'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Finalize the budget'), findsOneWidget);
    expect(find.text('Not analyzed yet'), findsNothing);
  });

  testWidgets('failed analysis surfaces the error and a Retry action',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final jobs = JobLocalDataSource(db);
    final engine = FakeEngineGateway();
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Draft',
      status: SessionStatus.ready,
      audioPath: '/tmp/s1.m4a',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncProvider.overrideWithValue(_CloudRemote.empty()),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Analyze'));
    await tester.pump();
    await tester.pump();
    engine.emit(failedJob(engine.created!, 'boom'));
    await tester.pump();
    await tester.pump();

    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Status: failed'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(engine.createCount, 2);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets(
      'shows alternative titles and item priority + low-confidence hints',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final base = Session(
      id: 's1',
      userId: 'u1',
      title: 'Budget talk',
      alternativeTitles: const ['Budget meeting', 'Cost review'],
      summary: 'We reviewed the budget.',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await sessions.insertSession(base);
    await sessions.updateSession(base.copyWith(topics: [
      Topic(
        id: 't1',
        position: 0,
        title: 'Budget',
        items: [
          Item(
            id: 'i1',
            type: ItemType.task,
            title: 'Finalize budget',
            position: 0,
            priority: Priority.high,
            confidence: 0.9,
          ),
          Item(
            id: 'i2',
            type: ItemType.idea,
            title: 'Maybe track usage',
            position: 1,
            confidence: 0.5,
          ),
        ],
      ),
    ]));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Budget meeting'), findsOneWidget);
    expect(find.text('Cost review'), findsOneWidget);
    expect(find.text('We reviewed the budget.'), findsOneWidget);

    await tester.tap(find.text('Budget'));
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.flag), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.text('Finalize budget'), findsOneWidget);
    expect(find.text('Maybe track usage'), findsOneWidget);
  });

  testWidgets('transcript card shows cleaned by default and toggles to original',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Meeting',
      status: SessionStatus.ready,
      originalTranscript: 'um the budget is due uh Friday',
      cleanedTranscript: 'The budget is due Friday.',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        versionRepositoryProvider.overrideWithValue(VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Cleaned transcript'), findsOneWidget);
    expect(find.text('The budget is due Friday.'), findsOneWidget);

    await tester.tap(find.text('Original'));
    await tester.pumpAndSettle();

    expect(find.text('Original transcript'), findsOneWidget);
    expect(find.text('um the budget is due uh Friday'), findsOneWidget);
    expect(find.text('The budget is due Friday.'), findsNothing);
  });

  testWidgets('transcript edit persists through the op log and undo reverts',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Meeting',
      status: SessionStatus.ready,
      originalTranscript: 'um the budget is due uh Friday',
      cleanedTranscript: 'The budget is due Friday.',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        editLogRepositoryProvider.overrideWithValue(
            EditLogLocalDataSource(db)),
        versionRepositoryProvider.overrideWithValue(
            VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'The budget is due on Friday.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      (await sessions.getSession('s1'))!.cleanedTranscript,
      'The budget is due on Friday.',
    );
    expect(find.text('The budget is due on Friday.'), findsOneWidget);

    await tester.tap(find.ancestor(
        of: find.byIcon(Icons.undo), matching: find.byType(IconButton)));
    await tester.pumpAndSettle();
    expect(
      (await sessions.getSession('s1'))!.cleanedTranscript,
      'The budget is due Friday.',
    );
  });

  testWidgets('re-analyze submits a transcript job without an input ref',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final jobs = JobLocalDataSource(db);
    final engine = FakeEngineGateway();
    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Meeting',
      status: SessionStatus.ready,
      originalTranscript: 'um the budget is due uh Friday',
      cleanedTranscript: 'The budget is due Friday.',
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        versionRepositoryProvider.overrideWithValue(
            VersionLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
        syncEngineProvider.overrideWithValue(
            SyncEngine(db: db, remote: _CloudRemote.empty())),
      ],
      child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Re-analyze'));
    await tester.pump();
    await tester.pump();

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.analyze);
    expect(engine.created!.inputRef, isNull);
    expect(engine.lastOptions!['input_kind'], 'transcript');
    expect(engine.lastOptions!['input_meta'],
        {'text': 'The budget is due Friday.'});
    expect(engine.lastOptions!['memory'], isA<List>());
    expect(find.text('Status: cleaning'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  group('editing UI (architecture §3.4)', () {
    Future<SessionLocalDataSource> pumpReady(
      WidgetTester tester, {
      required AppDatabase db,
      Session? session,
    }) async {
      final sessions = SessionLocalDataSource(db);
      final base = session ??
          Session(
            id: 's1',
            userId: 'u1',
            title: 'Budget',
            status: SessionStatus.ready,
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
            topics: const [
              Topic(
                id: 't1',
                position: 0,
                title: 'Costs',
                items: [
                  Item(
                    id: 'i1',
                    type: ItemType.task,
                    position: 0,
                    title: 'Finalize the budget',
                    confidence: 0.9,
                  ),
                ],
              ),
            ],
          );
      await sessions.insertSession(base);
      await sessions.updateSession(base);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(sessions),
          editLogRepositoryProvider.overrideWithValue(
              EditLogLocalDataSource(db)),
          versionRepositoryProvider.overrideWithValue(
              VersionLocalDataSource(db)),
          authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
          syncEngineProvider.overrideWithValue(
              SyncEngine(db: db, remote: _CloudRemote.empty())),
        ],
        child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
      ));
      await tester.pumpAndSettle();
      return sessions;
    }

    testWidgets('shows the edit toolbar with undo/redo disabled before edits',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await pumpReady(tester, db: db);

      expect(find.text('Add topic'), findsOneWidget);
      final undo = tester.widget<IconButton>(
          find.ancestor(
              of: find.byIcon(Icons.undo), matching: find.byType(IconButton)));
      final redo = tester.widget<IconButton>(
          find.ancestor(
              of: find.byIcon(Icons.redo), matching: find.byType(IconButton)));
      expect(undo.onPressed, isNull);
      expect(redo.onPressed, isNull);
    });

    testWidgets('edit-title dialog cancels without changes', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sessions = await pumpReady(tester, db: db);

      await tester.tap(find.byTooltip('Edit title'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect((await sessions.getSession('s1'))!.title, 'Budget');
      expect(find.text('Budget'), findsOneWidget);
    });

    testWidgets('editing the title persists, enables undo, and undo reverts',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sessions = await pumpReady(tester, db: db);

      await tester.tap(find.byTooltip('Edit title'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect((await sessions.getSession('s1'))!.title, 'Renamed');

      final undo = tester.widget<IconButton>(find.ancestor(
          of: find.byIcon(Icons.undo), matching: find.byType(IconButton)));
      expect(undo.onPressed, isNotNull);

      await tester.tap(find.byIcon(Icons.undo));
      await tester.pumpAndSettle();
      expect((await sessions.getSession('s1'))!.title, 'Budget');
      expect(find.text('Budget'), findsOneWidget);
    });

    testWidgets('item edit through the popup menu updates and clears confidence',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final sessions = await pumpReady(tester, db: db);

      await tester.tap(find.byTooltip('Expand'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Finalize the budget'), findsOneWidget);

      await tester.tap(find.byTooltip('Item actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, 'Done');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final item = (await sessions.getSession('s1'))!
          .topics
          .single
          .items
          .single;
      expect(item.title, 'Done');
      expect(item.confidence, isNull);

      await tester.tap(find.byIcon(Icons.undo));
      await tester.pumpAndSettle();
      final restored = (await sessions.getSession('s1'))!
          .topics
          .single
          .items
          .single;
      expect(restored.title, 'Finalize the budget');
      expect(restored.confidence, 0.9);
    });
  });

  group('audio card (§16)', () {
    Future<SessionLocalDataSource> pumpSession(
      WidgetTester tester, {
      required AppDatabase db,
      required FakeSessionAudioPlayer player,
      required Session session,
      List<Override> extra = const [],
    }) async {
      final sessions = SessionLocalDataSource(db);
      await sessions.insertSession(session);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(sessions),
          editLogRepositoryProvider.overrideWithValue(
              EditLogLocalDataSource(db)),
          versionRepositoryProvider.overrideWithValue(
              VersionLocalDataSource(db)),
          authRepositoryProvider.overrideWithValue(_SignedInAuth('u1')),
          syncEngineProvider.overrideWithValue(
              SyncEngine(db: db, remote: _CloudRemote.empty())),
          sessionAudioPlayerProvider.overrideWithValue(player),
          ...extra,
        ],
        child: const MaterialApp(home: SessionDetailScreen(sessionId: 's1')),
      ));
      await tester.pumpAndSettle();
      return sessions;
    }

    Session audioSession({String? audioPath = '/tmp/s1.m4a'}) => Session(
          id: 's1',
          userId: 'u1',
          title: 'Recording',
          status: SessionStatus.ready,
          audioPath: audioPath,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        );

    tearDown(() {
      // Drift `.watch()` streams keep a short-lived cache Timer.
    });

    testWidgets('shows play, seek, speed, and delete for a recorded session',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      await pumpSession(tester, db: db, player: FakeSessionAudioPlayer(),
          session: audioSession());

      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.text('0:00 / 0:00'), findsOneWidget);
      expect(find.text('1.0x'), findsOneWidget);
      expect(find.byTooltip('Delete recording'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
    });

    testWidgets('play loads the source and flips to pause with a duration',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final player = FakeSessionAudioPlayer();
      await pumpSession(tester, db: db, player: player,
          session: audioSession());

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await tester.pump();

      expect(player.setSourceCalls, 1);
      expect(player.source, '/tmp/s1.m4a');
      expect(player.playing, true);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.text('0:00 / 0:30'), findsOneWidget);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(player.playing, false);
      expect(find.byTooltip('Play'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
    });

    testWidgets('speed menu changes playback speed', (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final player = FakeSessionAudioPlayer();
      await pumpSession(tester, db: db, player: player,
          session: audioSession());

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byTooltip('Playback speed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();

      expect(player.speed, 1.5);
      expect(find.text('1.5x'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
    });

    testWidgets('delete recording confirms, removes the file, and clears the ref',
        (tester) async {
      // dart:io futures need the real event loop, so file work runs under
      // `tester.runAsync` (fake-async zones starve it on this platform).
      final dir = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('audio_card_test')))!;
      final file = File('${dir.path}/s1.m4a');
      await tester.runAsync(() => file.writeAsString('fake audio'));
      addTearDown(() async {
        try {
          await tester.runAsync(() => dir.delete(recursive: true));
        } catch (_) {}
      });

      final db = AppDatabase(NativeDatabase.memory());
      final player = FakeSessionAudioPlayer();
      final sessions = await pumpSession(tester, db: db, player: player,
          session: audioSession(audioPath: file.path));

      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      await tester.pump();
      expect(player.source, file.path);

      await tester.tap(find.byTooltip('Delete recording'));
      await tester.pumpAndSettle();
      expect(find.text('Delete recording?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => file.exists()), isTrue);
      expect((await sessions.getSession('s1'))!.audioPath, file.path);

      await tester.tap(find.byTooltip('Delete recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      // The card's `_delete` interleaves real file IO with fake-zone async
      // (playback + drift DB). Alternate real-async windows with pumps so both
      // sides make progress before asserting.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(await tester.runAsync(() => file.exists()), isFalse);
      expect((await sessions.getSession('s1'))!.audioPath, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
    });

    testWidgets('editing the session keeps the recording (spec §16)',
        (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final sessions = await pumpSession(
          tester,
          db: db,
          player: FakeSessionAudioPlayer(),
          session: audioSession());

      await tester.tap(find.byTooltip('Edit title'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final updated = (await sessions.getSession('s1'))!;
      expect(updated.title, 'Renamed');
      expect(updated.audioPath, '/tmp/s1.m4a');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
      await db.close();
    });
  });
}
