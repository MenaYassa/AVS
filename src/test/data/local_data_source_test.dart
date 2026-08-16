import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _memDb() => AppDatabase(NativeDatabase.memory());

void main() {
  late AppDatabase db;
  late SessionLocalDataSource dataSource;

  setUp(() {
    db = _memDb();
    dataSource = SessionLocalDataSource(db);
  });

  tearDown(() => db.close());

  test('insert + get session round-trips', () async {
    final session = Session(
      id: 's1',
      userId: 'u1',
      title: 'Hello',
      status: SessionStatus.recording,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.insertSession(session);

    final loaded = await dataSource.getSession('s1');
    expect(loaded, isNotNull);
    expect(loaded!.id, 's1');
    expect(loaded.title, 'Hello');
  });

  test('replaceTopics persists the tree and watchSessions emits it', () async {
    final session = Session(
      id: 's2',
      userId: 'u1',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.insertSession(session);

    await dataSource.replaceTopics('s2', [
      Topic(
        id: 't1',
        title: 'Benchmark Platform',
        position: 0,
        items: [
          Item(
            id: 'i1',
            type: ItemType.task,
            title: 'Add caching',
            position: 0,
            priority: Priority.high,
            confidence: 0.95,
          ),
        ],
      ),
    ]);

    final topicList = await dataSource.getTopics('s2');
    expect(topicList.single.title, 'Benchmark Platform');
    expect(topicList.single.items.single.type, ItemType.task);

    // stream reflects persisted content
    final streamed = await dataSource.watchSessions().first;
    expect(streamed.single.topics.single.items.single.title, 'Add caching');
  });

  test('updateSession replaces the knowledge tree atomically', () async {
    final session = Session(
      id: 's3',
      userId: 'u1',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.insertSession(session);
    await dataSource.replaceTopics('s3', [
      Topic(id: 't1', title: 'Old', position: 0),
    ]);

    final updated = session.copyWith(
      title: 'Renamed',
      topics: [Topic(id: 't2', title: 'New', position: 0)],
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.updateSession(updated);

    final topics = await dataSource.getTopics('s3');
    expect(topics.single.title, 'New');
    expect((await dataSource.getSession('s3'))!.title, 'Renamed');
  });

  test('deleteSession removes topics and items', () async {
    final session = Session(
      id: 's4',
      userId: 'u1',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.insertSession(session);
    await dataSource.replaceTopics('s4', [
      Topic(id: 't1', title: 'T', position: 0, items: [
        Item(id: 'i1', type: ItemType.idea, title: 'x', position: 0),
      ]),
    ]);

    await dataSource.deleteSession('s4');

    expect(await dataSource.getSession('s4'), isNull);
    expect(await dataSource.getTopics('s4'), isEmpty);
  });

  test('FTS virtual table is created and indexes sessions', () async {
    final session = Session(
      id: 's5',
      userId: 'u1',
      title: 'EAG Benchmark Platform Planning',
      status: SessionStatus.ready,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    );
    await dataSource.insertSession(session);

    final rows = await db.customSelect(
      "SELECT rowid FROM sessions_fts WHERE sessions_fts MATCH 'benchmark'",
    ).get();
    expect(rows, isNotEmpty);
  });

  test('mappers handle json helpers', () {
    expect(encodeJson({'a': 1}), '{"a":1}');
    expect(decodeJson('{"a":1}'), {'a': 1});
    expect(encodeJson(null), isNull);
  });
}
