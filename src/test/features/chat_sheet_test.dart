import 'dart:convert';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:ai_knowledge_companion/features/chat/chat_controller.dart';
import 'package:ai_knowledge_companion/features/chat/chat_sheet.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
  testWidgets('chat sheet shows example chips and answers a tapped example',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final jobs = JobLocalDataSource(db);
    final chat = ChatLocalDataSource(db);
    final engine = FakeEngineGateway();

    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Release planning',
      summary: 'We plan to ship v2 by Friday.',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        chatRepositoryProvider.overrideWithValue(chat),
        tagRepositoryProvider.overrideWithValue(TagLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ChatSheet(sessionId: 's1')),
      ),
    ));
    await tester.pumpAndSettle();

    // Empty conversation shows the example chips (spec §17).
    for (final example in kChatExamples) {
      expect(find.text(example), findsOneWidget);
    }

    // Tap an example; the question is persisted and the job is submitted.
    await tester.tap(find.text('What tasks are still open?'));
    // The answer spinner animates while the job is pending, so `pump` (not
    // `pumpAndSettle`) drives the async job submission to completion.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(engine.createCount, 1);
    expect(engine.created!.kind, JobKind.chat);
    expect(find.text('What tasks are still open?'), findsOneWidget);
    expect(find.text('Thinking…'), findsOneWidget);

    // Stream the grounded answer through the SSE fake.
    final job = engine.created!;
    engine.emit(job.copyWith(
      status: JobStatus.running,
      updatedAt: DateTime.now().toUtc(),
    ));
    await tester.pump();
    engine.emit(job.copyWith(
      status: JobStatus.succeeded,
      resultJson: jsonEncode({
        'question': 'What tasks are still open?',
        'session_id': 's1',
        'prompt_versions': {'chat': 1},
        'response': {
          'answer': 'Ship v2 by Friday.',
          'citations': ['[summary] Release planning'],
          'confidence': 0.9,
        },
      }),
      updatedAt: DateTime.now().toUtc(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(find.text('Ship v2 by Friday.'), findsOneWidget);
    expect(find.text('[summary] Release planning'), findsOneWidget);
    expect(find.text('Confidence 90%'), findsOneWidget);
    expect(find.text('Thinking…'), findsNothing);

    // Drift `.watch()` streams keep a short-lived cache timer; dispose the
    // tree, fire that timer, then close the DB before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    final messages = await tester.runAsync(
        () => chat.watchMessages('s1').first);
    expect(messages, hasLength(2));
    expect(messages!.last.isUser, isFalse);
  });

  testWidgets('composer sends a typed question and renders a user bubble',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final sessions = SessionLocalDataSource(db);
    final jobs = JobLocalDataSource(db);
    final chat = ChatLocalDataSource(db);
    final engine = FakeEngineGateway();

    await sessions.insertSession(Session(
      id: 's1',
      userId: 'u1',
      title: 'Release planning',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(sessions),
        jobProvider.overrideWithValue(jobs),
        engineGatewayProvider.overrideWithValue(engine),
        chatRepositoryProvider.overrideWithValue(chat),
        tagRepositoryProvider.overrideWithValue(TagLocalDataSource(db)),
        authRepositoryProvider.overrideWithValue(_SignedInAuth()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ChatSheet(sessionId: 's1')),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'What did I decide?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(engine.createCount, 1);
    expect(engine.lastOptions!['question'], 'What did I decide?');
    expect(find.text('What did I decide?'), findsOneWidget);

    // Dispose the tree before any direct DB read (fake-async zone would
    // otherwise starve the real `dart:io`/isolate future).
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
    final messages = await tester.runAsync(
        () => chat.watchMessages('s1').first);
    expect(messages!.single.isUser, isTrue);
    expect(messages.single.content, 'What did I decide?');
  });
}
