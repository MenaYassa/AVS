import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../domain/editing/conflict_resolver.dart';
import '../../domain/editing/operation_log.dart';
import '../../domain/editing/oplog_diff.dart';
import '../../domain/entities/chat_message.dart';
import '../../domain/entities/command_draft.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/graph.dart';
import '../../domain/entities/job.dart';
import '../../domain/entities/provider_setting.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/entities/semantic_search_result.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/session_version.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';
import '../mappers/mappers.dart';
import 'database.dart';
import 'vector_codec.dart';

/// Local-first persistence over drift (architecture §3.2, §5.3).
///
/// Implements the Domain repository interfaces. The app reads/writes SQLite
/// synchronously and syncs via the write-through outbox (§4.13): every session
/// mutation is committed together with a pending outbox record.

class SessionLocalDataSource implements SessionRepository {
  SessionLocalDataSource(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) {
    return _db.sessionsDao
        .watchSessions(includeDeleted: includeDeleted)
        .asyncMap((rows) async {
      final sessions = <Session>[];
      for (final row in rows) {
        sessions.add(await _loadSession(row));
      }
      return sessions;
    });
  }

  Future<Session> _loadSession(SessionRow row) async {
    final topics = await _db.sessionsDao.getTopics(row.id);
    final itemRows = await _db.sessionsDao
        .getItemsForTopics(topics.map((t) => t.id).toList());
    final session = sessionFromRow(
        row, topics.map((t) => topicFromRow(t, itemRows)).toList());
    return _hydrateGraph(session);
  }

  /// Loads the session's knowledge subgraph and attaches it (architecture
  /// §4.8). The graph lives in its own tables; sessions hydrate it on read.
  Future<Session> _hydrateGraph(Session session) async {
    final dao = _db.graphDao;
    final nodes = await dao.entitiesForSession(session.id);
    final confidence = await dao.sessionConfidence(session.id);
    final edges = await dao.relationsForSession(session.id);
    final nodeIds = {for (final n in nodes) n.id};
    return session.copyWith(
      entities: [
        for (final n in nodes)
          entityFromRow(n).copyWith(confidence: confidence[n.id]),
      ],
      relationships: [
        for (final e in edges)
          if (nodeIds.contains(e.sourceId) && nodeIds.contains(e.targetId))
            relationFromRow(e),
      ],
    );
  }

  @override
  Future<Session?> getSession(String id) async {
    final row = await _db.sessionsDao.getSession(id);
    if (row == null) return null;
    return _loadSession(row);
  }

  @override
  Future<Session> insertSession(Session session) async {
    await _db.transaction(() async {
      await _db.sessionsDao.insertSession(sessionToRow(session));
      await _enqueueUpsert(session);
    });
    return session;
  }

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async {
    await _db.transaction(() async {
      await _db.sessionsDao.updateSession(sessionToRow(session));
      if (session.topics.isNotEmpty) {
        await _db.sessionsDao.replaceTopics(
          session.id,
          session.topics.map((t) {
            final row = topicToRow(session, t);
            return (
              topic: row,
              items: t.items.map((i) => itemToRow(t, i)).toList(),
            );
          }).toList(),
        );
      }
      await _persistGraph(session);
      if (emitDiff) {
        // Op-log-driven edits sync as lossless diffs (§4.13), never as
        // full-document replacement. The actual ops + base snapshot are read
        // from the op-log at drain time, so undo/redo before sync is exact.
        await _enqueueDiff(session);
      } else {
        await _enqueueUpsert(session);
      }
    });
  }

  /// Writes the session's knowledge subgraph (architecture §4.8) unless neither
  /// the stored nor the new graph has any membership — avoiding a rewrite on
  /// every edit of graph-less sessions.
  Future<void> _persistGraph(Session session) async {
    if (!await _db.graphDao.sessionHasGraph(session.id) &&
        session.entities.isEmpty) {
      return;
    }
    await _db.graphDao.replaceSubgraph(
      session.id,
      [for (final e in session.entities) entityToRow(e)],
      {for (final e in session.entities) e.id: e.confidence},
      [for (final r in session.relationships) relationToRow(r, sessionId: session.id)],
    );
  }

  @override
  Future<void> deleteSession(String id) async {
    await _db.transaction(() async {
      final row = await _db.sessionsDao.getSession(id);
      if (row == null) return; // already gone; nothing to sync
      await _db.sessionsDao.deleteSession(id);
      await (_db.delete(_db.embeddings)..where((t) => t.sessionId.equals(id))).go();
      await _enqueue(SyncOutboxRow(
        id: _uuid.v4(),
        userId: row.userId,
        entityType: 'session',
        entityId: id,
        op: 'delete',
        payloadJson: null,
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ));
    });
  }

  Future<void> _enqueueUpsert(Session session) {
    final canonical = session.toCanonicalJson();
    return _enqueue(SyncOutboxRow(
      id: _uuid.v4(),
      userId: session.userId,
      entityType: 'session',
      entityId: session.id,
      op: 'upsert',
      // Canonical content + the sync-relevant timestamp the engine needs to
      // keep the pull cursor monotonic (architecture §5.1, §4.13).
      payloadJson: jsonEncode({
        'session': canonical['session'],
        'updated_at': session.updatedAt?.toIso8601String(),
      }),
      status: 'pending',
      attempts: 0,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  /// Records that a session has unsynced op-log edits. The diff payload is
  /// derived from the op-log at drain time (§4.13); this record only marks the
  /// session so the sync engine knows to resolve and push it.
  Future<void> _enqueueDiff(Session session) {
    return _enqueue(SyncOutboxRow(
      id: _uuid.v4(),
      userId: session.userId,
      entityType: 'session',
      entityId: session.id,
      op: 'oplog_diff',
      payloadJson: jsonEncode({'session_id': session.id}),
      status: 'pending',
      attempts: 0,
      createdAt: DateTime.now().toUtc(),
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  Future<void> _enqueue(SyncOutboxRow row) => _db.syncDao.enqueue(row);

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) {
    return _db.sessionsDao.replaceTopics(
      sessionId,
      topics.map((t) {
        final row = topicToRow(Session(id: sessionId, userId: ''), t);
        return (
          topic: row,
          items: t.items.map((i) => itemToRow(t, i)).toList(),
        );
      }).toList(),
    );
  }

  @override
  Future<List<Topic>> getTopics(String sessionId) async {
    final topicRows = await _db.sessionsDao.getTopics(sessionId);
    final itemRows = await _db.sessionsDao
        .getItemsForTopics(topicRows.map((t) => t.id).toList());
    return topicRows.map((t) => topicFromRow(t, itemRows)).toList();
  }
}

class JobLocalDataSource implements JobRepository {
  JobLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Stream<Job?> watchJob(String id) =>
      _db.jobsDao.watchJob(id).map((row) => row == null ? null : jobFromRow(row));

  @override
  Future<Job?> getJob(String id) async {
    final row = await _db.jobsDao.getJob(id);
    return row == null ? null : jobFromRow(row);
  }

  @override
  Future<Job> insertJob(Job job) async {
    await _db.jobsDao.upsert(jobToRow(job));
    return job;
  }

  @override
  Future<void> updateJob(Job job) async {
    await _db.jobsDao.upsert(jobToRow(job));
  }
}

class ProviderSettingsLocalDataSource implements ProviderSettingsRepository {
  ProviderSettingsLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Future<List<ProviderSetting>> getAll() async {
    final rows = await _db.providerSettingsDao.getAll();
    return rows.map(providerSettingFromRow).toList();
  }

  @override
  Future<void> save(ProviderSetting setting) async {
    await _db.providerSettingsDao.upsert(providerSettingToRow(setting));
  }

  @override
  Future<void> delete(String id) => _db.providerSettingsDao.deleteById(id);
}

class TagLocalDataSource implements TagRepository {
  TagLocalDataSource(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  @override
  Future<List<Tag>> getAll() async {
    final rows = await _db.tagsDao.getAll();
    return rows.map(tagFromRow).toList();
  }

  @override
  Future<List<Tag>> getTagsForSession(String sessionId) async {
    final rows = await _db.tagsDao.getTagsForSession(sessionId);
    return rows.map(tagFromRow).toList();
  }

  @override
  Stream<List<Tag>> watchTagsForSession(String sessionId) {
    return _db.tagsDao
        .watchTagsForSession(sessionId)
        .map((rows) => rows.map(tagFromRow).toList());
  }

  @override
  Future<void> save(Tag tag) async {
    await _db.transaction(() async {
      await _db.tagsDao.upsert(tagToRow(tag));
      await _enqueueTag(tag, op: 'upsert');
    });
  }

  @override
  Future<void> delete(String id) async {
    await _db.transaction(() async {
      final row = await _db.tagsDao.getById(id);
      if (row == null) return; // already gone; nothing to sync
      await _db.tagsDao.deleteById(id);
      await _enqueue(
        SyncOutboxRow(
          id: _uuid.v4(),
          userId: row.userId,
          entityType: 'tag',
          entityId: id,
          op: 'delete',
          payloadJson: null,
          status: 'pending',
          attempts: 0,
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    });
  }

  @override
  Future<void> attachTag({
    required String sessionId,
    required String tagId,
  }) async {
    await _db.transaction(() async {
      await _db.tagsDao.attachTag(sessionId, tagId);
      await _enqueueSessionTag(sessionId, tagId, op: 'upsert');
    });
  }

  @override
  Future<void> detachTag({
    required String sessionId,
    required String tagId,
  }) async {
    await _db.transaction(() async {
      await _db.tagsDao.detachTag(sessionId, tagId);
      await _enqueueSessionTag(sessionId, tagId, op: 'delete');
    });
  }

  @override
  Future<void> setSessionTags(String sessionId, List<String> tagIds) async {
    await _db.transaction(() async {
      final current = await _db.tagsDao.getTagsForSession(sessionId);
      final currentIds = current.map((t) => t.id).toSet();
      final target = tagIds.toSet();
      await _db.tagsDao.setSessionTags(sessionId, tagIds);
      for (final tagId in target.difference(currentIds)) {
        await _enqueueSessionTag(sessionId, tagId, op: 'upsert');
      }
      for (final tagId in currentIds.difference(target)) {
        await _enqueueSessionTag(sessionId, tagId, op: 'delete');
      }
    });
  }

  Future<void> _enqueueTag(Tag tag, {required String op}) {
    return _enqueue(
      SyncOutboxRow(
        id: _uuid.v4(),
        userId: tag.userId,
        entityType: 'tag',
        entityId: tag.id,
        op: op,
        payloadJson: jsonEncode({
          'name': tag.name,
          if (tag.color != null) 'color': tag.color,
          'user_id': tag.userId,
        }),
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _enqueueSessionTag(
    String sessionId,
    String tagId, {
    required String op,
  }) {
    return _enqueue(
      SyncOutboxRow(
        id: _uuid.v4(),
        userId: '',
        entityType: 'session_tag',
        entityId: '$sessionId:$tagId',
        op: op,
        payloadJson: op == 'upsert'
            ? jsonEncode({'session_id': sessionId, 'tag_id': tagId})
            : null,
        status: 'pending',
        attempts: 0,
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  Future<void> _enqueue(SyncOutboxRow row) => _db.syncDao.enqueue(row);
}

class GraphLocalDataSource implements GraphRepository {
  GraphLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Future<List<GraphEntity>> getEntities() async {
    final rows = await _db.graphDao.getEntities();
    return rows.map(entityFromRow).toList();
  }

  @override
  Future<List<GraphRelation>> getRelations() async {
    final rows = await _db.graphDao.getRelations();
    return rows.map(relationFromRow).toList();
  }

  @override
  Future<SessionGraph> getSubgraph(String sessionId) async {
    final dao = _db.graphDao;
    final nodes = await dao.entitiesForSession(sessionId);
    final confidence = await dao.sessionConfidence(sessionId);
    final edges = await dao.relationsForSession(sessionId);
    final byId = {for (final e in nodes) e.id: e};
    return SessionGraph(
      entities: [
        for (final n in nodes) entityFromRow(n).copyWith(confidence: confidence[n.id]),
      ],
      relationships: [
        for (final e in edges)
          if (byId.containsKey(e.sourceId) && byId.containsKey(e.targetId))
            relationFromRow(e),
      ],
    );
  }

  @override
  Future<List<GraphEntity>> traverse(String rootId, {int maxDepth = 3}) async {
    final rows = await _db.graphDao.traverse(rootId, maxDepth: maxDepth);
    return rows.map(entityFromRow).toList();
  }

  @override
  Future<List<String>> sessionIdsForEntity(String entityId) async {
    final rows = await (_db.select(_db.sessionEntities)
          ..where((t) => t.entityId.equals(entityId)))
        .get();
    return rows.map((r) => r.sessionId).toList();
  }

  @override
  Future<void> saveEntity(GraphEntity entity) async {
    await _db.graphDao.upsertEntity(entityToRow(entity));
  }

  @override
  Future<void> saveRelation(GraphRelation relation) async {
    await _db.graphDao.upsertRelation(relationToRow(relation));
  }

  @override
  Future<void> replaceSubgraph(String sessionId, SessionGraph graph) async {
    await _db.graphDao.replaceSubgraph(
      sessionId,
      [for (final e in graph.entities) entityToRow(e)],
      {for (final e in graph.entities) e.id: e.confidence},
      [
        for (final r in graph.relationships)
          relationToRow(r, sessionId: sessionId),
      ],
    );
  }

  @override
  Future<void> deleteEntity(String id) => _db.graphDao.deleteEntity(id);

  @override
  Future<void> deleteRelation(String id) => _db.graphDao.deleteRelation(id);
}

/// Per-user privacy preferences over the schema v3 `app_meta` key/value table
/// (spec §18, architecture §12). No new schema version: these are simple
/// key/value rows like the seed marker.
class AppSettingsLocalDataSource implements AppSettingsRepository {
  AppSettingsLocalDataSource(this._db);

  final AppDatabase _db;

  static const _deleteAudioKey = 'delete_audio_after_processing';
  static const _enableInsightsKey = 'enable_cross_session_insights';
  static const _enableMemoryKey = 'enable_ai_memory';
  static const _memorySkipKey = 'memory_skip';

  Future<String?> _read(String key) async {
    final rows = await _db.customSelect(
      'SELECT value FROM app_meta WHERE key = ?',
      variables: [Variable.withString(key)],
    ).get();
    return rows.isEmpty ? null : rows.single.read<String?>('value');
  }

  @override
  Future<bool> getDeleteAudioAfterProcessing(String userId) async {
    final value = await _read('$_deleteAudioKey:$userId');
    return value == 'true';
  }

  @override
  Future<void> setDeleteAudioAfterProcessing(
    String userId,
    bool value,
  ) async {
    await _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaRow(
          key: '$_deleteAudioKey:$userId',
          value: '$value',
        ));
  }

  @override
  Future<bool> getEnableInsights(String userId) async {
    final value = await _read('$_enableInsightsKey:$userId');
    return value == 'true';
  }

  @override
  Future<void> setEnableInsights(
    String userId,
    bool value,
  ) async {
    await _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaRow(
          key: '$_enableInsightsKey:$userId',
          value: '$value',
        ));
  }

  @override
  Future<bool> getEnableMemory(String userId) async {
    final value = await _read('$_enableMemoryKey:$userId');
    return value == 'true';
  }

  @override
  Future<void> setEnableMemory(String userId, bool value) async {
    await _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaRow(
          key: '$_enableMemoryKey:$userId',
          value: '$value',
        ));
  }

  @override
  Future<bool> getMemorySkip(String sessionId) async {
    final value = await _read('$_memorySkipKey:$sessionId');
    return value == 'true';
  }

  @override
  Future<void> setMemorySkip(String sessionId, bool value) async {
    await _db.into(_db.appMeta).insertOnConflictUpdate(AppMetaRow(
          key: '$_memorySkipKey:$sessionId',
          value: '$value',
        ));
  }
}

class EditLogLocalDataSource implements EditLogRepository {
  EditLogLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Future<OperationLog?> getLog(String sessionId) async {
    final row = await _db.editLogDao.get(sessionId);
    if (row == null) return null;
    return OperationLog.fromJson(
      jsonDecode(row.logJson) as Map<String, dynamic>,
    );
  }

  @override
  Future<void> saveLog(
    String sessionId,
    OperationLog log, {
    Session? diffBase,
  }) async {
    final existing = await _db.editLogDao.get(sessionId);
    final before = existing == null
        ? OperationLog()
        : OperationLog.fromJson(
            jsonDecode(existing.logJson) as Map<String, dynamic>,
          );

    // Capture the diff base on the clean -> dirty transition: the session
    // state before the first unsynced edit. Later mutations keep the original
    // base so base-relative positions stay anchored to the true start.
    final becameDirty = (before.cursor == before.syncWatermark) &&
        (log.cursor != log.syncWatermark);
    final baseJson = becameDirty && diffBase != null
        ? jsonEncode(diffBase.toCanonicalJson())
        : existing?.baseSnapshotJson;

    await _db.editLogDao.save(SessionOplogRow(
      sessionId: sessionId,
      logJson: jsonEncode(log.toJson()),
      baseSnapshotJson: baseJson,
      updatedAt: DateTime.now().toUtc(),
    ));
  }

  @override
  Future<OplogDiff?> getPendingDiff(String sessionId) async {
    final row = await _db.editLogDao.get(sessionId);
    if (row == null) return null;
    final log = OperationLog.fromJson(
      jsonDecode(row.logJson) as Map<String, dynamic>,
    );
    final batches = log.unsyncedDelta();
    if (batches.isEmpty) return null;
    if (row.baseSnapshotJson == null) return null;
    return OplogDiff(
      sessionId: sessionId,
      base: Session.fromCanonicalJson(
        jsonDecode(row.baseSnapshotJson!) as Map<String, dynamic>,
        userId: sessionId,
      ),
      batches: batches,
      emittedAt: DateTime.now().toUtc(),
    );
  }

  @override
  Future<void> markSynced(String sessionId, {required Session base}) async {
    final row = await _db.editLogDao.get(sessionId);
    if (row == null) return;
    final log = OperationLog.fromJson(
      jsonDecode(row.logJson) as Map<String, dynamic>,
    )..markSynced();
    await _db.editLogDao.save(SessionOplogRow(
      sessionId: sessionId,
      logJson: jsonEncode(log.toJson()),
      baseSnapshotJson: jsonEncode(base.toCanonicalJson()),
      updatedAt: DateTime.now().toUtc(),
    ));
  }
}

class SyncConflictLocalDataSource implements ConflictRepository {
  SyncConflictLocalDataSource(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  @override
  Future<void> addAll(String sessionId, List<SessionConflict> conflicts) async {
    if (conflicts.isEmpty) return;
    for (final conflict in conflicts) {
      await _db.syncConflictDao.insert(SyncConflictRow(
        id: _uuid.v4(),
        sessionId: sessionId,
        kind: conflict.kind,
        description: conflict.description,
        fieldPath: conflict is FieldConflict ? conflict.fieldPath : null,
        localValue: conflict is FieldConflict
            ? conflict.localValue?.toString()
            : null,
        remoteValue: conflict is FieldConflict
            ? conflict.remoteValue?.toString()
            : null,
        createdAt: DateTime.now().toUtc(),
      ));
    }
  }

  @override
  Future<List<SessionConflict>> forSession(String sessionId) async {
    final rows = await _db.syncConflictDao.forSession(sessionId);
    return [
      for (final row in rows)
        if (row.kind == 'field')
          FieldConflict(
            sessionId: row.sessionId,
            fieldPath: row.fieldPath ?? '',
            localValue: row.localValue,
            remoteValue: row.remoteValue,
          )
        else
          StructuralConflict(
            sessionId: row.sessionId,
            opType: '',
            target: row.description,
          ),
    ];
  }

  @override
  Future<void> clear(String sessionId) =>
      _db.syncConflictDao.clearForSession(sessionId);
}

class VersionLocalDataSource implements VersionRepository {

  VersionLocalDataSource(this._db);

  final AppDatabase _db;
  final Uuid _uuid = const Uuid();

  SessionVersion _fromRow(SessionVersionRow row) {
    final snapshot = Session.fromCanonicalJson(
      jsonDecode(row.snapshotJson) as Map<String, dynamic>,
      userId: row.sessionId,
    );
    return SessionVersion(
      id: row.id,
      sessionId: row.sessionId,
      versionNo: row.versionNo,
      snapshot: snapshot,
      promptVersions: row.promptVersionsJson == null
          ? const {}
          : (jsonDecode(row.promptVersionsJson!) as Map<String, dynamic>),
      changeReason: row.changeReason,
      createdAt: row.createdAt,
    );
  }

  @override
  Future<List<SessionVersion>> getVersions(String sessionId) async {
    // The DAO returns newest-first; the repository contract is oldest-first so
    // consumers can treat the last entry as the current head.
    final rows = await _db.versionsDao.forSession(sessionId);
    return rows.reversed.map(_fromRow).toList();
  }

  @override
  Future<SessionVersion> commit(SessionVersion version) async {
    // Serialize commits per session: the version number is the max+1 so two
    // concurrent commits can't produce a duplicate.
    final versionNo = await _db.versionsDao.nextVersion(version.sessionId);
    final stored = version.copyWith(
      id: version.id.isEmpty ? _uuid.v4() : version.id,
      versionNo: versionNo,
    );
    await _db.versionsDao.insert(SessionVersionRow(
      id: stored.id,
      sessionId: stored.sessionId,
      versionNo: stored.versionNo,
      snapshotJson: jsonEncode(stored.snapshot.toCanonicalJson()),
      promptVersionsJson: stored.promptVersions.isEmpty
          ? null
          : jsonEncode(stored.promptVersions),
      changeReason: stored.changeReason,
      createdAt: stored.createdAt ?? DateTime.now().toUtc(),
    ));
    return stored;
  }

  @override
  Future<SessionVersion?> getVersion(String sessionId, int versionNo) async {
    final rows = await _db.versionsDao.forSession(sessionId);
    for (final row in rows) {
      if (row.versionNo == versionNo) return _fromRow(row);
    }
    return null;
  }
}

/// FTS5-backed search over the schema v6 index (architecture §5.3). The index
/// is maintained by triggers on `sessions`/`topics`/`items`, so results are
/// always current with the content tables.
class SearchLocalDataSource implements SearchRepository {
  SearchLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Future<List<SearchResult>> search(String query) async {
    final hits = await _db.searchDao.search(query);
    return [
      for (final hit in hits)
        SearchResult(
          sessionId: hit.sessionId,
          title: hit.title,
          summary: hit.summary,
          status: SessionStatus.fromWire(hit.status) ?? SessionStatus.recording,
          rank: hit.rank,
          snippet: hit.snippet,
        ),
    ];
  }
}

/// On-device embeddings for semantic search (schema v10, architecture §5.3).
/// Vectors are stored as float32 blobs in the `embeddings` table and ranked in
/// Dart with cosine similarity (`vector_codec.dart`); local-first so semantic
/// retrieval works from the synced index.
class EmbeddingLocalDataSource implements EmbeddingRepository {
  EmbeddingLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Future<void> upsertSessionEmbedding({
    required String sessionId,
    required String scope,
    required String contentRef,
    required List<double> vector,
  }) async {
    await _db.into(_db.embeddings).insertOnConflictUpdate(EmbeddingRow(
      id: '$sessionId:$scope',
      sessionId: sessionId,
      scope: scope,
      contentRef: contentRef,
      vector: encodeFloat32(vector),
    ));
  }

  @override
  Future<List<double>?> embeddingForSession(String sessionId) async {
    final row = await (_db.select(_db.embeddings)
          ..where((t) => t.sessionId.equals(sessionId) & t.scope.equals('local')))
        .getSingleOrNull();
    final bytes = row?.vector;
    if (bytes == null) return null;
    return decodeFloat32(bytes);
  }

  @override
  Future<void> deleteSessionEmbeddings(String sessionId) =>
      (_db.delete(_db.embeddings)..where((t) => t.sessionId.equals(sessionId))).go();

  @override
  Future<List<String>> sessionsWithoutLocalEmbedding() async {
    final embeddedRows = await (_db.select(_db.embeddings)
          ..where((t) => t.scope.equals('local')))
        .get();
    final embedded = embeddedRows.map((e) => e.sessionId).toSet();
    final analyzed = await (_db.select(_db.sessions)
          ..where((t) =>
              t.deleted.equals(false) &
              t.status.isIn(['ready', 'edited', 'synced'])))
        .get();
    return [
      for (final row in analyzed)
        if (!embedded.contains(row.id)) row.id,
    ];
  }

  @override
  Future<List<SemanticSearchResult>> searchSimilar(
    List<double> queryVector, {
    int limit = 20,
    double threshold = 0.7,
    String? excludeSessionId,
  }) async {
    if (queryVector.isEmpty || limit <= 0) return const [];
    final rows = await (_db.select(_db.embeddings)
          ..where((t) => t.scope.equals('local') & t.vector.isNotNull()))
        .get();

    final scored = <(String sessionId, double similarity, List<double> vector)>[];
    for (final row in rows) {
      if (row.vector == null) continue;
      if (excludeSessionId != null && row.sessionId == excludeSessionId) {
        continue;
      }
      final similarity = cosineSimilarity(queryVector, decodeFloat32(row.vector!));
      if (similarity < threshold) continue;
      scored.add((row.sessionId, similarity, decodeFloat32(row.vector!)));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final top = scored.take(limit).toList();
    if (top.isEmpty) return const [];

    final meta = await _db.sessionsDao
        .metaForIds(top.map((e) => e.$1).toList());
    return [
      for (final (sessionId, similarity, _) in top)
        SemanticSearchResult(
          sessionId: sessionId,
          title: meta[sessionId]?.title,
          summary: meta[sessionId]?.summary,
          status: SessionStatus.fromWire(meta[sessionId]?.status ?? '') ??
              SessionStatus.recording,
          similarity: similarity,
        ),
    ];
  }
}

/// AI command drafts local persistence (schema v8, architecture §4.11).
/// Drafts are local-only and do not participate in the sync/op-log path
/// until the user explicitly saves them into a session.
class DraftLocalDataSource implements DraftRepository {
  DraftLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Stream<List<CommandDraft>> watchDrafts(String sessionId) {
    return _db.draftDao
        .watchDrafts(sessionId)
        .map((rows) => rows.map(draftFromRow).toList());
  }

  @override
  Future<CommandDraft?> getDraft(String id) async {
    final row = await _db.draftDao.getDraft(id);
    return row == null ? null : draftFromRow(row);
  }

  @override
  Future<CommandDraft> saveDraft(CommandDraft draft) async {
    await _db.draftDao.upsert(draftToRow(draft));
    return draft;
  }

@override
  Future<void> deleteDraft(String id) =>
      _db.draftDao.deleteDraft(id);
}

/// Per-session AI chat history local persistence (schema v9, §4.11, spec §17).
/// Local-only — chat rides no sync/op-log path.
class ChatLocalDataSource implements ChatRepository {
  ChatLocalDataSource(this._db);

  final AppDatabase _db;

  @override
  Stream<List<ChatMessage>> watchMessages(String sessionId) {
    return _db.chatDao
        .watchMessages(sessionId)
        .map((rows) => rows.map(chatMessageFromRow).toList());
  }

  @override
  Future<void> addMessage(ChatMessage message) async {
    await _db.chatDao.upsert(chatMessageToRow(message));
  }
}
