import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/command_draft.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/commands/draft_screen.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/analysis_fakes.dart';

class _FakeAuth implements AuthRepository {
  _FakeAuth(this.id);

  final String? id;

  @override
  String? get currentUserId => id;

  @override
  Stream<String?> watchUserId() => const Stream.empty();

  @override
  Future<void> signInWithGoogle() async {}

  @override
  Future<void> signOut() async {}
}

void main() {
  testWidgets('draft menu pushes the edited draft to a connected plugin',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final drafts = DraftLocalDataSource(db);
    final sessions = SessionLocalDataSource(db);
    final engine = FakeEngineGateway()..connectedPlugins.add('notion');

    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Standup',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
    await drafts.saveDraft(CommandDraft(
      id: 'd1',
      sessionId: 's1',
      command: 'summarize',
      title: 'Today',
      body: 'Done work.',
      items: [
        DraftItem(title: 'Ship plugin', body: 'tests pass', type: ItemType.task),
      ],
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        draftRepositoryProvider.overrideWithValue(drafts),
        editLogRepositoryProvider.overrideWithValue(EditLogLocalDataSource(db)),
        engineGatewayProvider.overrideWithValue(engine),
        authRepositoryProvider.overrideWithValue(_FakeAuth('u1')),
      ],
      child: const MaterialApp(
        home: DraftScreen(args: DraftScreenArgs(sessionId: 's1', draftId: 'd1')),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Today'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pumpAndSettle();
    expect(find.text('Push to Notion'), findsOneWidget);

    await tester.tap(find.text('Push to Notion'));
    await tester.pumpAndSettle();

    expect(engine.lastPushedDraft, isNotNull);
    expect(engine.lastPushedDraft!['title'], 'Today');
    expect(engine.lastPushedDraft!['body'], 'Done work.');
    final items = engine.lastPushedDraft!['items'] as List<dynamic>;
    expect(items, hasLength(1));
    expect(items.single['title'], 'Ship plugin');
    expect(items.single['type'], 'task');
    expect(find.textContaining('Pushed to Notion'), findsOneWidget);
  });
}
