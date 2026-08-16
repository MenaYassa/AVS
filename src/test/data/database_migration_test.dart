import 'dart:io';

import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

// Migration strategy + versioned seed (architecture §5.3, roadmap §1.2).
//
// Every test drives the real `onCreate`/`onUpgrade`/seed path against a file
// database, so the exact SQL that ships to users is what is exercised.

const _seedRows = 7;

Future<AppDatabase> _open(String path) async {
  final db = AppDatabase(NativeDatabase(File(path)));
  await db.customSelect('SELECT 1').get();
  return db;
}

/// Closes [db] and rewinds it to an older schema: drops the tables that did
/// not exist at [version] and pins `PRAGMA user_version`.
Future<void> _pinVersion(
    AppDatabase db, String path, int version, List<String> drop) async {
  await db.transaction(() async {
    for (final t in drop) {
      await db.customStatement('DROP TABLE IF EXISTS $t');
    }
    await db.customStatement('PRAGMA user_version = $version');
  });
  await db.close();
}

Future<int> _userVersion(AppDatabase db) async {
  final row = await db.customSelect('PRAGMA user_version').get();
  return row.single.read<int>('user_version');
}

Future<int> _seedVersion(AppDatabase db) async {
  final rows = await db
      .customSelect("SELECT value FROM app_meta WHERE key = 'seed_version'")
      .get();
  return rows.isEmpty ? 0 : int.parse(rows.single.read<String>('value'));
}

Future<List<ProviderSettingRow>> _seededProviders(AppDatabase db) =>
    db.providerSettingsDao.getAll();

SessionRow _session(String id, {String userId = 'u1'}) => SessionRow(
      id: id,
      userId: userId,
      status: 'ready',
      favorite: false,
      archived: false,
      deleted: false,
      pinned: false,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

SyncOutboxRow _outbox(String id) => SyncOutboxRow(
      id: id,
      userId: 'u1',
      entityType: 'session',
      entityId: 's1',
      op: 'upsert',
      status: 'pending',
      attempts: 0,
      createdAt: DateTime.utc(2026, 8, 6, 10),
      updatedAt: DateTime.utc(2026, 8, 6, 10),
    );

/// Drops the schema v7 `pinned` column so a database can be rewound to a
/// pre-v7 version; `onUpgrade`'s `from < 7` branch then re-adds it.
Future<void> _dropPinnedColumn(AppDatabase db) =>
    db.customStatement('ALTER TABLE sessions DROP COLUMN pinned');

/// Drops the schema v6 search tables and triggers so a database can be rewound
/// to a pre-v6 version; `onUpgrade` then recreates them from scratch.
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

Future<void> _expectSearchIndex(AppDatabase db) async {
  final tables = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type='table' AND name IN "
    "('search_content', 'search_fts')",
  ).get();
  expect(tables.map((r) => r.read<String>('name')).toSet(),
      containsAll({'search_content', 'search_fts'}));
  final triggers = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'search_%'",
  ).get();
  expect(triggers.map((r) => r.read<String>('name')),
      containsAll([
        'search_sess_ai',
        'search_sess_au',
        'search_sess_ad',
        'search_topic_ai',
        'search_topic_au',
        'search_topic_ad',
        'search_item_ai',
        'search_item_au',
        'search_item_ad',
      ]));
}

void main() {
  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('drift_migration');
    dbPath = '${dir.path}/test.sqlite';
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('fresh create (onCreate)', () {
    test('creates v10 schema, search index and runs seed v1 exactly once',
        () async {
      final db = await _open(dbPath);

      expect(await _userVersion(db), 10);
      expect(await _seedVersion(db), 1);
      final providers = await _seededProviders(db);
      expect(providers, hasLength(_seedRows));
      expect(providers.map((p) => p.userId).toSet(), {'local'});
      expect(providers.every((p) => !p.enabled), isTrue);
      expect(providers.map((p) => p.provider),
          containsAll(['openai_whisper', 'deepgram', 'openai', 'ollama']));

      final fts = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'sessions_fts'",
      ).get();
      expect(fts, hasLength(1));
      final oplog = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'session_oplog'",
      ).get();
      expect(oplog, hasLength(1));
      final conflicts = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'sync_conflicts'",
      ).get();
      expect(conflicts, hasLength(1));
      final oplogCols = await db.customSelect(
        'PRAGMA table_info(session_oplog)',
      ).get();
      expect(oplogCols.map((r) => r.read<String>('name')),
          contains('base_snapshot_json'));
      await _expectSearchIndex(db);

      // v7 adds the pinned column (roadmap §4.2).
      final sessionCols = await db.customSelect(
        'PRAGMA table_info(sessions)',
      ).get();
      expect(sessionCols.map((r) => r.read<String>('name')), contains('pinned'));

      // v8 adds the drafts table (architecture §4.11).
      final drafts = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'drafts'",
      ).get();
      expect(drafts, hasLength(1));

      // v9 adds the chat messages table (architecture §4.11, spec §17).
      final chat = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'chat_messages'",
      ).get();
      expect(chat, hasLength(1));

      // v10 adds the embeddings table (architecture §5.3 semantic index).
      final embeddings = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'embeddings'",
      ).get();
      expect(embeddings, hasLength(1));

      await db.close();
    });

    test('seed is idempotent across reopens and never clobbers user edits',
        () async {
      final db = await _open(dbPath);
      // A user configures the openai_whisper row.
      await db.providerSettingsDao.upsert(
          (await _seededProviders(db))
              .firstWhere((p) => p.provider == 'openai_whisper')
              .copyWith(enabled: true));
      await db.close();

      final reopened = await _open(dbPath);
      expect(await _seedVersion(reopened), 1);
      expect(await _seededProviders(reopened), hasLength(_seedRows));
      final configured = (await _seededProviders(reopened))
          .singleWhere((p) => p.provider == 'openai_whisper');
      expect(configured.enabled, isTrue);

      await reopened.close();
    });
  });

  group('v1 -> v10 upgrade', () {
    test('adds sync + app_meta + search tables, keeps data, seeds defaults',
        () async {
      // Build a v1 database: current schema minus the v2+ tables.
      final v1 = await _open(dbPath);
      await v1.into(v1.sessions).insert(_session('s1'));
      await v1.into(v1.topics).insert(TopicRow(
            id: 't1',
            sessionId: 's1',
            position: 0,
            title: 'Benchmark',
            description: '',
          ));
      await _dropPinnedColumn(v1);
      await _dropSearchSchema(v1);
      await _pinVersion(v1, dbPath, 1,
          ['sync_outbox', 'sync_state', 'app_meta', 'session_oplog', 'sync_conflicts']);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);
      expect(await _seedVersion(db), 1);
      expect(await _seededProviders(db), hasLength(_seedRows));
      await _expectSearchIndex(db);

      // Pre-existing rows survived the upgrade, with the FTS trigger intact.
      final session = await db.sessionsDao.getSession('s1');
      expect(session?.title, isNull); // raw insert above only set required cols
      expect(session, isNotNull);
      final topics = await db.sessionsDao.getTopics('s1');
      expect(topics.single.title, 'Benchmark');

      await db.sessionsDao.upsertSession(_session('s1'));
      expect((await db.sessionsDao.getSession('s1'))?.status, 'ready');

      await db.close();
    });
  });

  group('v2 -> v10 upgrade', () {
    test('preserves sync_outbox records and applies the seed', () async {
      final v2 = await _open(dbPath);
      await v2.into(v2.sessions).insert(_session('s1'));
      await v2.into(v2.syncOutbox).insert(_outbox('outbox-1'));
      await _dropPinnedColumn(v2);
      await _dropSearchSchema(v2);
      await _pinVersion(v2, dbPath, 2, ['app_meta', 'session_oplog', 'sync_conflicts']);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);
      expect(await _seedVersion(db), 1);
      expect(await _seededProviders(db), hasLength(_seedRows));
      await _expectSearchIndex(db);

      final pending = await db.syncDao.peekPending();
      expect(pending, hasLength(1));
      expect(pending.single.id, 'outbox-1');
      expect(pending.single.op, 'upsert');

      await db.close();
    });
  });

  group('v4 -> v10 upgrade', () {
    test('adds sync_conflicts + base snapshot column, keeps oplog data',
        () async {
      final v4 = await _open(dbPath);
      await v4.into(v4.sessions).insert(_session('s1'));
      await v4.into(v4.sessionOplog).insert(SessionOplogRow(
            sessionId: 's1',
            logJson: '{"batches":[],"cursor":0,"sync_watermark":0}',
            updatedAt: DateTime.utc(2026, 8, 6, 10),
          ));
      // Rewind to v4: drop the v5 table and the v5 column, then pin the version.
      await v4.customStatement(
          'ALTER TABLE session_oplog DROP COLUMN base_snapshot_json');
      await _dropPinnedColumn(v4);
      await _dropSearchSchema(v4);
      await _pinVersion(v4, dbPath, 4, ['sync_conflicts']);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);
      expect(await _seedVersion(db), 1);

      final conflicts = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'sync_conflicts'",
      ).get();
      expect(conflicts, hasLength(1));
      final oplogCols = await db.customSelect(
        'PRAGMA table_info(session_oplog)',
      ).get();
      expect(oplogCols.map((r) => r.read<String>('name')),
          contains('base_snapshot_json'));
      await _expectSearchIndex(db);

      // Pre-existing oplog row survived with a null base snapshot (v4 data).
      final oplog = await db.editLogDao.get('s1');
      expect(oplog?.logJson, contains('"cursor":0'));
      expect(oplog?.baseSnapshotJson, isNull);

      await db.close();
    });
  });

  group('v5 -> v10 upgrade', () {
    test('adds the search index and backfills existing sessions', () async {
      final v5 = await _open(dbPath);
      await v5.into(v5.sessions).insert(_session('s1'));
      await _dropPinnedColumn(v5);
      await _dropSearchSchema(v5);
      await _pinVersion(v5, dbPath, 5, const []);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);
      await _expectSearchIndex(db);

      // Backfill: the upgraded search_content holds the pre-existing session.
      final content = await db.customSelect(
        "SELECT content FROM search_content WHERE session_id = 's1'",
      ).get();
      expect(content, hasLength(1));

      await db.close();
    });
  });

  group('v6 -> v10 upgrade', () {
    test('adds the pinned column and preserves existing sessions', () async {
      final v6 = await _open(dbPath);
      await v6.into(v6.sessions).insert(_session('s1'));
      // Rewind to v6: drop the v7 column, then pin the version.
      await v6.customStatement('ALTER TABLE sessions DROP COLUMN pinned');
      await _pinVersion(v6, dbPath, 6, const []);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);

      // Pinned column exists and pre-existing rows survived with a false default.
      final sessionCols = await db.customSelect(
        'PRAGMA table_info(sessions)',
      ).get();
      expect(sessionCols.map((r) => r.read<String>('name')), contains('pinned'));
      final session = await db.sessionsDao.getSession('s1');
      expect(session, isNotNull);
      expect(session?.pinned, isFalse);

      await db.close();
    });
  });

  group('v8 -> v10 upgrade', () {
    test('adds the chat messages table and preserves existing sessions',
        () async {
      final v8 = await _open(dbPath);
      await v8.into(v8.sessions).insert(_session('s1'));
      await _pinVersion(v8, dbPath, 8, ['chat_messages']);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);

      // The chat table exists and pre-existing sessions survived.
      final chat = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'chat_messages'",
      ).get();
      expect(chat, hasLength(1));
      final session = await db.sessionsDao.getSession('s1');
      expect(session, isNotNull);

      // Messages round-trip through the ChatDao.
      await db.chatDao.upsert(ChatMessageRow(
        id: 'm1',
        sessionId: 's1',
        role: 'user',
        content: 'What tasks are still open?',
        createdAt: DateTime.utc(2026, 8, 10, 10),
      ));
      final messages = await db.chatDao.watchMessages('s1').first;
      expect(messages, hasLength(1));
      expect(messages.single.role, 'user');
      expect(messages.single.content, 'What tasks are still open?');

      await db.close();
    });
  });

  group('v9 -> v10 upgrade', () {
    test('recreates the embeddings table and preserves sessions', () async {
      final v9 = await _open(dbPath);
      await v9.into(v9.sessions).insert(_session('s1'));
      // Rewind to v9: drop the v10 table, then pin the version.
      await _pinVersion(v9, dbPath, 9, ['embeddings']);

      final db = await _open(dbPath);
      expect(await _userVersion(db), 10);

      // The guarded CREATE TABLE IF NOT EXISTS guarantees the table exists.
      final embeddings = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = 'embeddings'",
      ).get();
      expect(embeddings, hasLength(1));
      final session = await db.sessionsDao.getSession('s1');
      expect(session, isNotNull);

      // Embeddings round-trip through the local data source.
      await db.into(db.embeddings).insertOnConflictUpdate(EmbeddingRow(
        id: 's1:local',
        sessionId: 's1',
        scope: 'local',
        contentRef: '',
        vector: null,
      ));
      final row = await (db.select(db.embeddings)..where((t) => t.sessionId.equals('s1')))
          .getSingleOrNull();
      expect(row?.scope, 'local');

      await db.close();
    });
  });
}
