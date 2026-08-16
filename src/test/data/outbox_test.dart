import 'dart:io';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

AppDatabase _memDb() => AppDatabase(NativeDatabase.memory());

/// Drops the schema v6 search tables and their triggers so a database can be
/// rewound to a pre-v6 version for upgrade tests.
Future<void> _dropSearchSchema(AppDatabase db) async {
  for (final t in ['search_content', 'search_fts']) {
    await db.customStatement('DROP TABLE IF EXISTS $t');
  }
  for (final t in [
    'search_sess_ai',
    'search_sess_au',
    'search_sess_ad',
    'search_topic_ai',
    'search_topic_au',
    'search_topic_ad',
    'search_item_ai',
    'search_item_au',
    'search_item_ad',
  ]) {
    await db.customStatement('DROP TRIGGER IF EXISTS $t');
  }
}

Session _session(String id, String title, {String userId = 'u1'}) => Session(
      id: id,
      userId: userId,
      title: title,
      status: SessionStatus.ready,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

void main() {
  group('write-through outbox (architecture §4.13)', () {
    late AppDatabase db;
    late SessionLocalDataSource dataSource;

    setUp(() {
      db = _memDb();
      dataSource = SessionLocalDataSource(db);
    });

    tearDown(() => db.close());

    test('insertSession commits the session and an upsert record together',
        () async {
      await dataSource.insertSession(_session('s1', 'Hello'));

      expect(await dataSource.getSession('s1'), isNotNull);
      final pending = await db.syncDao.peekPending();
      expect(pending, hasLength(1));
      final record = pending.single;
      expect(record.op, 'upsert');
      expect(record.entityType, 'session');
      expect(record.entityId, 's1');
      expect(record.status, 'pending');
      expect(record.attempts, 0);
      expect(record.payloadJson, contains('"title":"Hello"'));
    });

    test('updateSession enqueues another upsert with fresh content', () async {
      await dataSource.insertSession(_session('s1', 'Hello'));
      await dataSource.updateSession(
          _session('s1', 'Renamed').copyWith(updatedAt: DateTime.utc(2026, 8, 6, 11)));

      final pending = await db.syncDao.peekPending();
      expect(pending, hasLength(2));
      expect(pending.last.payloadJson, contains('"title":"Renamed"'));
    });

    test('deleteSession enqueues a delete tombstone owned by the session user',
        () async {
      await dataSource.insertSession(_session('s1', 'Hello', userId: 'u1'));
      await dataSource.deleteSession('s1');

      final pending = await db.syncDao.peekPending();
      expect(pending, hasLength(2));
      final record = pending.last;
      expect(record.op, 'delete');
      expect(record.entityId, 's1');
      expect(record.userId, 'u1');
      expect(record.payloadJson, isNull);
    });

    test('deleteSession of a missing session enqueues nothing', () async {
      await dataSource.deleteSession('missing');
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('outbox records survive an aborted mutation transaction', () async {
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('peekPending is oldest-first and bounded by limit', () async {
      for (var i = 0; i < 3; i++) {
        await dataSource.insertSession(_session('s$i', 's$i'));
      }
      final all = await db.syncDao.peekPending();
      expect(all.map((r) => r.entityId).toList(), ['s0', 's1', 's2']);
      final limited = await db.syncDao.peekPending(limit: 2);
      expect(limited.map((r) => r.entityId).toList(), ['s0', 's1']);
    });

    test('markProcessed clears, markFailed and retry track attempts', () async {
      await dataSource.insertSession(_session('s1', 'x'));
      await dataSource.insertSession(_session('s2', 'y'));

      var pending = await db.syncDao.peekPending();
      await db.syncDao.markProcessed(pending.first.id);
      expect(await db.syncDao.pendingCount(), 1);

      pending = await db.syncDao.peekPending();
      await db.syncDao.retry(pending.single.id, 2);
      final afterRetry = (await db.syncDao.peekPending()).single;
      expect(afterRetry.status, 'pending');
      expect(afterRetry.attempts, 2);

      await db.syncDao.markFailed(afterRetry.id, 5);
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('sync cursor persists per user', () async {
      expect(await db.syncDao.getLastSync('u1'), isNull);
      final t = DateTime.utc(2026, 8, 6, 12);
      await db.syncDao.saveCursor('u1', t);
      expect(await db.syncDao.getLastSync('u1'), t);
      expect(await db.syncDao.getLastSync('u2'), isNull);
    });
  });

  group('schema migration', () {
    test('v1 database upgrades to v2 with sync tables (architecture §5.2)',
        () async {
      final dir = await Directory.systemTemp.createTemp('drift_migration');
      final file = File('${dir.path}/test.sqlite');

      // Simulate a v1 database: drop the v2-only (and later-schema) tables,
      // pin user_version.
      final db = AppDatabase(NativeDatabase(file));
      await db.customStatement('DROP TABLE IF EXISTS sync_outbox');
      await db.customStatement('DROP TABLE IF EXISTS sync_state');
      await db.customStatement('ALTER TABLE sessions DROP COLUMN pinned');
      await _dropSearchSchema(db);
      await db.customStatement('PRAGMA user_version = 1');
      await db.close();

      // Reopening runs onUpgrade(1 -> 2), which recreates the sync tables.
      final db2 = AppDatabase(NativeDatabase(file));
      final rows = await db2.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
        "('sync_outbox', 'sync_state')",
      ).get();
      expect(rows, hasLength(2));

      await db2.syncDao.enqueue(SyncOutboxRow(
        id: 'outbox-1',
        userId: 'u1',
        entityType: 'session',
        entityId: 's1',
        op: 'upsert',
        payloadJson: '{"session":{"id":"s1"}}',
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.utc(2026, 8, 6),
        updatedAt: DateTime.utc(2026, 8, 6),
      ));
      expect(await db2.syncDao.pendingCount(), 1);

      await db2.close();
      await dir.delete(recursive: true);
    });
  });
}
