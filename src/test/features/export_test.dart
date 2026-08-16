import 'dart:io';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/features/export/session_exporter.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async {
      if (call.method == 'getTemporaryDirectory') {
        return (await Directory.systemTemp.createTemp('export_test')).path;
      }
      return null;
    },
  );

  late AppDatabase db;
  late TagLocalDataSource tags;

  Session draft(String id, {
    String? title,
    String? summary,
    List<String> topicTitles = const [],
    List<String> taskTitles = const [],
  }) =>
      Session(
        id: id,
        userId: 'u1',
        title: title ?? 'Session $id',
        summary: summary ?? 'Summary of session $id',
        status: SessionStatus.ready,
        topics: [
          Topic(
            id: 't-$id-1',
            title: topicTitles.isNotEmpty ? topicTitles.first : 'Topic 1',
            description: 'Description of topic 1',
            position: 0,
            items: [
              for (final t in taskTitles)
                Item(
                  id: 'i-$id-$t',
                  type: ItemType.task,
                  title: t,
                  description: '',
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
    tags = TagLocalDataSource(db);
  });

  tearDown(() => db.close());

  test('toMarkdown includes title, summary, topics, items', () async {
    final session = draft('s1',
      title: 'My Session',
      summary: 'A summary',
      topicTitles: ['Topic A'],
      taskTitles: ['Do something'],
    );
    final exporter = SessionExporter(session, []);

    final file = await exporter.toMarkdown();
    final content = await file.readAsString();

    expect(content, contains('# My Session'));
    expect(content, contains('## Summary'));
    expect(content, contains('A summary'));
    expect(content, contains('## Topics'));
    expect(content, contains('Topic A'));
    expect(content, contains('Do something'));
    expect(content, endsWith('\n'));
  });

  test('toJson includes session fields and tags', () async {
    final session = draft('s1', title: 'JSON Test');
    final tag = Tag(id: 't1', userId: 'u1', name: 'work');
    await tags.save(tag);
    await tags.attachTag(sessionId: 's1', tagId: 't1');

    final exporter = SessionExporter(session, [tag]);
    final file = await exporter.toJson();
    final content = await file.readAsString();

    expect(content, contains('"title": "JSON Test"'));
    expect(content, contains('"tags"'));
    expect(content, contains('"name": "work"'));
  });

  test('toPlainText renders topics as flat outline', () async {
    final session = draft('s1',
      title: 'Plain',
      summary: 'Summary',
      topicTitles: ['Topic X'],
    );
    final exporter = SessionExporter(session, []);

    final file = await exporter.toPlainText();
    final content = await file.readAsString();

    expect(content, contains('Plain'));
    expect(content, contains('SUMMARY'));
    expect(content, contains('TOPICS'));
    expect(content, contains('Topic X'));
  });

  test('toPdf generates a PDF file', () async {
    final session = draft('s1', title: 'PDF Export');
    final exporter = SessionExporter(session, []);

    final file = await exporter.toPdf();
    expect(file.existsSync(), true);
    final bytes = await file.readAsBytes();
    expect(bytes.isNotEmpty, true);
    // PDF starts with %PDF
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
  });
}