import 'package:ai_knowledge_companion/data/local/database.dart';
import 'package:ai_knowledge_companion/data/local/local_data_source.dart';
import 'package:ai_knowledge_companion/data/sync/sync_engine.dart';
import 'package:ai_knowledge_companion/domain/editing/conflict_resolver.dart';
import 'package:ai_knowledge_companion/domain/editing/edit_operations.dart';
import 'package:ai_knowledge_companion/domain/editing/operation_log.dart';
import 'package:ai_knowledge_companion/domain/entities/enums.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/entities/tag.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRemote implements SyncRepository {
  final Map<String, Session> cloud = {};
  final Map<String, Tag> tags = {};
  final Map<String, Set<String>> sessionTags = {};
  final List<String> deletedIds = [];
  final List<DateTime> pullSince = [];
  bool failPush = false;
  bool failPull = false;

  @override
  Future<void> pushSession(Session session) async {
    if (failPush) throw Exception('offline');
    cloud[session.id] = session;
  }

  @override
  Future<void> pushTag(Tag tag) async {
    if (failPush) throw Exception('offline');
    tags[tag.id] = tag;
  }

  @override
  Future<void> deleteTag({
    required String userId,
    required String tagId,
  }) async {
    if (failPush) throw Exception('offline');
    tags.remove(tagId);
    // Mirrors the cloud `session_tags.tag_id ... on delete cascade` FK.
    for (final e in sessionTags.values) {
      e.remove(tagId);
    }
  }

  @override
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  }) async {
    if (failPush) throw Exception('offline');
    sessionTags.putIfAbsent(sessionId, () => {}).add(tagId);
  }

  @override
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  }) async {
    if (failPush) throw Exception('offline');
    sessionTags[sessionId]?.remove(tagId);
  }

  @override
  Future<List<Tag>> pullTags(String userId) async {
    if (failPull) throw Exception('offline');
    return tags.values.where((t) => t.userId == userId).toList();
  }

  @override
  Future<List<SessionTag>> pullSessionTags(String userId) async {
    if (failPull) throw Exception('offline');
    return [
      for (final e in sessionTags.entries)
        for (final tagId in e.value) SessionTag(sessionId: e.key, tagId: tagId),
    ];
  }

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {
    if (failPush) throw Exception('offline');
    deletedIds.add(sessionId);
    final existing = cloud[sessionId];
    cloud[sessionId] = existing == null
        ? Session(
            id: sessionId,
            userId: userId,
            deleted: true,
            updatedAt: DateTime.utc(2030, 1, 1),
          )
        : existing.copyWith(deleted: true, updatedAt: DateTime.utc(2030, 1, 1));
  }

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async {
    if (failPull) throw Exception('offline');
    pullSince.add(since);
    return cloud.values
        .where((s) => s.userId == userId)
        .where((s) => s.updatedAt != null && s.updatedAt!.isAfter(since))
        .toList()
      ..sort((a, b) => a.updatedAt!.compareTo(b.updatedAt!));
  }

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async {
    if (failPull) throw Exception('offline');
    final s = cloud[sessionId];
    return (s != null && s.userId == userId) ? s : null;
  }

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {}
}

AppDatabase _memDb() => AppDatabase(NativeDatabase.memory());

Session _session(String id, String title,
        {String userId = 'u1', required DateTime updated}) =>
    Session(
      id: id,
      userId: userId,
      title: title,
      status: SessionStatus.ready,
      createdAt: updated,
      updatedAt: updated,
    );

final _t1 = DateTime.utc(2026, 8, 6, 10);
final _t2 = DateTime.utc(2026, 8, 6, 11);

void main() {
  late AppDatabase db;  late _FakeRemote remote;
  late SyncEngine engine;
  late SessionLocalDataSource local;
  late EditLogLocalDataSource logs;

  setUp(() {
    db = _memDb();
    remote = _FakeRemote();
    engine = SyncEngine(db: db, remote: remote);
    local = SessionLocalDataSource(db);
    logs = EditLogLocalDataSource(db);
  });

  tearDown(() => db.close());

  test('push drains the outbox and delivers canonical content', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));

    final result = await engine.sync(userId: 'u1');

    expect(result.pushed, 1);
    expect(result.failed, 0);
    expect(remote.cloud['s1']?.title, 'Hello');
    expect(remote.cloud['s1']?.updatedAt, _t1);
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('local delete becomes a cloud tombstone', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    await engine.sync(userId: 'u1');
    await local.deleteSession('s1');

    final result = await engine.sync(userId: 'u1');

    expect(remote.deletedIds, ['s1']);
    expect(remote.cloud['s1']?.deleted, isTrue);
    expect(result.pushed, 1);
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('transient push failure retries, then succeeds once online', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    remote.failPush = true;

    final failed = await engine.sync(userId: 'u1');
    expect(failed.failed, 1);
    expect(remote.cloud, isEmpty);
    final record = (await db.syncDao.peekPending()).single;
    expect(record.status, 'pending');
    expect(record.attempts, 1);

    remote.failPush = false;
    final ok = await engine.sync(userId: 'u1');
    expect(ok.pushed, 1);
    expect(remote.cloud['s1']?.title, 'Hello');
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('repeated failures are marked failed after maxAttempts', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    remote.failPush = true;

    for (var i = 0; i < SyncEngine.maxAttempts; i++) {
      await engine.sync(userId: 'u1');
    }
    expect(await db.syncDao.pendingCount(), 0);
    expect(remote.cloud, isEmpty);
  });

  test('pull applies cloud sessions and advances the cursor', () async {
    remote.cloud['c1'] = _session('c1', 'Cloud 1', updated: _t1);
    remote.cloud['c2'] = _session('c2', 'Cloud 2', updated: _t2);

    final result = await engine.sync(userId: 'u1');

    expect(result.pulled, 2);
    expect((await local.getSession('c1'))?.title, 'Cloud 1');
    expect((await local.getSession('c2'))?.title, 'Cloud 2');
    expect(await db.syncDao.getLastSync('u1'), _t2);
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('second pull is incremental from the saved cursor', () async {
    remote.cloud['c1'] = _session('c1', 'Cloud 1', updated: _t1);
    await engine.sync(userId: 'u1');
    expect(remote.pullSince, [_epoch]);

    remote.cloud['c2'] = _session('c2', 'Cloud 2', updated: _t2);
    await engine.sync(userId: 'u1');

    expect(remote.pullSince.last, _t1);
    expect((await local.getSession('c2'))?.title, 'Cloud 2');
  });

  test('pull tombstone removes the local copy without re-enqueuing', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    await engine.sync(userId: 'u1'); // push -> cloud
    await remote.deleteSession(userId: 'u1', sessionId: 's1'); // cloud tombstone

    final result = await engine.sync(userId: 'u1');

    expect(result.deleted, 1);
    expect(await local.getSession('s1'), isNull);
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('pull never enqueues outbox records (no sync loop)', () async {
    remote.cloud['c1'] = _session('c1', 'Cloud 1', updated: _t1);
    await engine.sync(userId: 'u1');
    remote.cloud['c2'] = _session('c2', 'Cloud 2', updated: _t2);
    await engine.sync(userId: 'u1');

    expect(await db.syncDao.pendingCount(), 0);
  });

  test('round-trip: local edit converges to the cloud', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    await engine.sync(userId: 'u1');

    await local.updateSession(_session('s1', 'Renamed', updated: _t2));
    await engine.sync(userId: 'u1');

    expect(remote.cloud['s1']?.title, 'Renamed');
    expect(await db.syncDao.pendingCount(), 0);
  });

  test('pull failure is tolerated and leaves the cursor untouched', () async {
    await local.insertSession(_session('s1', 'Hello', updated: _t1));
    remote.failPull = true;

    final result = await engine.sync(userId: 'u1');

    expect(result.pulled, 0);
    expect(await db.syncDao.getLastSync('u1'), isNull);
    expect(await db.syncDao.pendingCount(), 0);
  });

  group('op-log diff drain (architecture §4.13)', () {
    test('an edit syncs as a diff against the cloud state', () async {
      final base = _session('s1', 'Hello', updated: _t1);
      await local.insertSession(base);
      await engine.sync(userId: 'u1');
      expect(remote.cloud['s1']?.title, 'Hello');

      final log = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'Hello', newTitle: 'Renamed'));
      await logs.saveLog('s1', log, diffBase: base);
      await local.updateSession(
        base.copyWith(title: 'Renamed', updatedAt: _t2),
        emitDiff: true,
      );

      final result = await engine.sync(userId: 'u1');

      expect(result.pushed, 1);
      expect(result.conflicts, 0);
      expect(remote.cloud['s1']?.title, 'Renamed');
      expect(await logs.getPendingDiff('s1'), isNull); // watermark advanced
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('a never-synced session resolves against its own diff base', () async {
      final base = _session('s1', 'Hello', updated: _t1);
      await local.insertSession(base);

      final log = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'Hello', newTitle: 'Local'));
      await logs.saveLog('s1', log, diffBase: base);
      await local.updateSession(
        base.copyWith(title: 'Local', updatedAt: _t2),
        emitDiff: true,
      );

      final result = await engine.sync(userId: 'u1');

      // Insert's upsert + the diff both drain; the diff replays on its base.
      expect(result.pushed, 2);
      expect(result.conflicts, 0);
      expect(remote.cloud['s1']?.title, 'Local');
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('a conflicting cloud edit is flagged, local wins, conflict persists',
        () async {
      final base = _session('s1', 'Hello', updated: _t1);
      await local.insertSession(base);
      await engine.sync(userId: 'u1');
      // The other device renamed the session while we were offline.
      remote.cloud['s1'] = remote.cloud['s1']!.copyWith(
        title: 'Remote',
        updatedAt: _t1.add(const Duration(hours: 1)),
      );

      final log = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'Hello', newTitle: 'Local'));
      await logs.saveLog('s1', log, diffBase: base);
      await local.updateSession(
        base.copyWith(title: 'Local', updatedAt: _t2),
        emitDiff: true,
      );

      final result = await engine.sync(userId: 'u1');

      expect(result.conflicts, 1);
      expect(remote.cloud['s1']?.title, 'Local'); // local (later) wins
      final stored = await SyncConflictLocalDataSource(db).forSession('s1');
      expect(stored, hasLength(1));
      final field = stored.single as FieldConflict;
      expect(field.fieldPath, 'session.title');
      expect(field.remoteValue, 'Remote');
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('a diff record with nothing unsynced drains without pushing', () async {
      final base = _session('s1', 'Hello', updated: _t1);
      await local.insertSession(base);
      await engine.sync(userId: 'u1');

      // Edit then undo before any sync: no net change to emit.
      final log = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'Hello', newTitle: 'Temp'))
        ..undo();
      await logs.saveLog('s1', log, diffBase: base);
      await local.updateSession(
        base.copyWith(updatedAt: _t2),
        emitDiff: true,
      );

      final result = await engine.sync(userId: 'u1');

      expect(result.pushed, 1);
      expect(result.conflicts, 0);
      expect(remote.cloud['s1']?.title, 'Hello'); // cloud untouched
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('a second edit anchors on the previously-merged state', () async {
      final base = _session('s1', 'Hello', updated: _t1);
      await local.insertSession(base);
      await engine.sync(userId: 'u1');

      final log1 = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'Hello', newTitle: 'One'));
      await logs.saveLog('s1', log1, diffBase: base);
      await local.updateSession(
        base.copyWith(title: 'One', updatedAt: _t2),
        emitDiff: true,
      );
      final first = await engine.sync(userId: 'u1');
      expect(first.conflicts, 0);
      expect(remote.cloud['s1']?.title, 'One');

      final log2 = OperationLog()
        ..apply(const UpdateSessionTitle(oldTitle: 'One', newTitle: 'Two'));
      await logs.saveLog(
        's1',
        log2,
        diffBase: base.copyWith(title: 'One', updatedAt: _t2),
      );
      await local.updateSession(
        base.copyWith(title: 'Two', updatedAt: _t2),
        emitDiff: true,
      );

      final second = await engine.sync(userId: 'u1');

      expect(second.conflicts, 0);
      expect(remote.cloud['s1']?.title, 'Two');
      expect(await db.syncDao.pendingCount(), 0);
    });
  });

  group('tag + session_tag drain (roadmap §4.2)', () {
    late TagLocalDataSource tags;
    late SessionLocalDataSource sessionsLocal;

    setUp(() {
      tags = TagLocalDataSource(db);
      sessionsLocal = SessionLocalDataSource(db);
    });

    test('tag ops drain as outbox records and land on the cloud', () async {
      await sessionsLocal.insertSession(_session('s1', 'Hello', updated: _t1));
      await tags.save(const Tag(id: 'tag1', userId: 'u1', name: 'ideas'));
      await tags.attachTag(sessionId: 's1', tagId: 'tag1');
      await engine.sync(userId: 'u1');

      expect(remote.tags['tag1']?.name, 'ideas');
      expect(remote.sessionTags['s1'], contains('tag1'));
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('tag delete + detach tombstone the cloud records', () async {
      await sessionsLocal.insertSession(_session('s1', 'Hello', updated: _t1));
      await tags.save(const Tag(id: 'tag1', userId: 'u1', name: 'ideas'));
      await tags.attachTag(sessionId: 's1', tagId: 'tag1');
      await engine.sync(userId: 'u1');

      await tags.delete('tag1');
      await engine.sync(userId: 'u1');

      expect(remote.tags, isEmpty);
      expect(remote.sessionTags['s1'], isNot(contains('tag1')));
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('tag pull refreshes tags and joins for locally-known sessions',
        () async {
      remote.cloud['c1'] = _session('c1', 'Cloud 1', updated: _t1);
      remote.tags['tag1'] = const Tag(id: 'tag1', userId: 'u1', name: 'ideas');
      remote.sessionTags['c1'] = {'tag1'};

      await engine.sync(userId: 'u1');

      expect(await db.tagsDao.getAll(), hasLength(1));
      final joined = await db.tagsDao.getTagsForSession('c1');
      expect(joined.single.name, 'ideas');
      expect(await db.syncDao.pendingCount(), 0);
    });

    test('a tag joined to an unknown session is dropped on pull', () async {
      remote.tags['tag1'] = const Tag(id: 'tag1', userId: 'u1', name: 'ideas');
      remote.sessionTags['ghost'] = {'tag1'};

      await engine.sync(userId: 'u1');

      // The orphan join is ignored; the tag itself still lands (it may be
      // attached to other sessions on the next pass).
      expect(await db.tagsDao.getAll(), hasLength(1));
    });
  });
}

final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
