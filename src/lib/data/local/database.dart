import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

part 'database.g.dart';

/// Drift database for schema v10 (architecture §5.3). v2 added the sync
/// outbox + cursor tables (§4.13); v3 adds `app_meta` for the versioned seed;
/// v9 adds the per-session AI chat messages table (§4.11); v10 guarantees the
/// `embeddings` table exists on every path (fresh DBs already created it via
/// `createAll`, upgraded DBs get `CREATE TABLE IF NOT EXISTS`).
@DriftDatabase(
  tables: [
    Sessions,
    Topics,
    Items,
    SessionVersions,
    Tags,
    SessionTags,
    Entities,
    SessionEntities,
    Relationships,
    Jobs,
    ProviderSettings,
    Embeddings,
    SyncOutbox,
    SyncState,
    AppMeta,
    SessionOplog,
    SyncConflicts,
    SearchContent,
    Drafts,
    ChatMessages,
  ],
  daos: [
    SessionsDao,
    JobsDao,
    ProviderSettingsDao,
    TagsDao,
    GraphDao,
    VersionsDao,
    SyncDao,
    EditLogDao,
    SyncConflictDao,
    SearchDao,
    DraftDao,
    ChatDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  AppDatabase.open() : super(driftDatabase(name: 'ai_knowledge'));

  @override
  int get schemaVersion => 10;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
        onCreate: (m) async {
          await m.createAll();
          await customStatement(
              'CREATE VIRTUAL TABLE sessions_fts USING fts5(title, alt_titles, summary, original_transcript, cleaned_transcript, content=\'sessions\', content_rowid=\'rowid\')');
          await customStatement(
              'CREATE TRIGGER sessions_ai AFTER INSERT ON sessions BEGIN INSERT INTO sessions_fts(rowid, title, alt_titles, summary, original_transcript, cleaned_transcript) VALUES (new.rowid, new.title, new.alt_titles_json, new.summary, new.original_transcript, new.cleaned_transcript); END');
          await customStatement(
              'CREATE TRIGGER sessions_ad AFTER DELETE ON sessions BEGIN INSERT INTO sessions_fts(sessions_fts, rowid, title, alt_titles, summary, original_transcript, cleaned_transcript) VALUES (\'delete\', old.rowid, old.title, old.alt_titles_json, old.summary, old.original_transcript, old.cleaned_transcript); END');
          await customStatement(
              'CREATE TRIGGER sessions_au AFTER UPDATE ON sessions BEGIN INSERT INTO sessions_fts(sessions_fts, rowid, title, alt_titles, summary, original_transcript, cleaned_transcript) VALUES (\'delete\', old.rowid, old.title, old.alt_titles_json, old.summary, old.original_transcript, old.cleaned_transcript); INSERT INTO sessions_fts(rowid, title, alt_titles, summary, original_transcript, cleaned_transcript) VALUES (new.rowid, new.title, new.alt_titles_json, new.summary, new.original_transcript, new.cleaned_transcript); END');
          await _createSearchIndex();
          await _runSeeds();
        },
        onUpgrade: (m, from, to) async {
          // Versioned chain: every bump adds exactly the delta for that step.
          // Never fall back to `createAll()` here — that would clobber data.
          if (from < 2) {
            await m.createTable(syncOutbox);
            await m.createTable(syncState);
          }
          if (from < 3) {
            await m.createTable(appMeta);
          }
          if (from < 4) {
            await m.createTable(sessionOplog);
          }
          if (from < 5) {
            await m.createTable(syncConflicts);
            // The column ships in the current table definition, so a fresh
            // createTable above (from < 4) already has it; only v4 databases
            // need the additive column change.
            if (from >= 4) {
              await m.addColumn(sessionOplog, sessionOplog.baseSnapshotJson);
            }
          }
          if (from < 6) {
            // v6 adds the searchable-content denormalization + FTS index.
            await m.createTable(searchContent);
            await _createSearchIndex();
            await _backfillSearchIndex();
          }
          if (from < 7) {
            // v7 adds the `pinned` organization flag (§4.2 "pinned sessions").
            await m.addColumn(sessions, sessions.pinned);
          }
          if (from < 8) {
            // v8 adds the AI command draft table (§4.11, spec §23).
            await m.createTable(drafts);
          }
          if (from < 9) {
            // v9 adds the per-session AI chat messages table (§4.11, spec §17).
            await m.createTable(chatMessages);
          }
          if (from < 10) {
            // v10 guarantees the `embeddings` table (§5.3 semantic index).
            // Fresh v9 databases already created it via `createAll`, so use a
            // guarded statement; upgraded databases get it created now.
            await customStatement('''
CREATE TABLE IF NOT EXISTS embeddings (
  id TEXT NOT NULL PRIMARY KEY,
  session_id TEXT NOT NULL,
  scope TEXT NOT NULL,
  content_ref TEXT NOT NULL,
  vector BLOB
)''');
          }
          await _runSeeds();
        },
      );

  /// Runs the versioned seed once per database. Safe on every create/upgrade:
  /// inserts are `INSERT OR IGNORE` and progress is recorded in `app_meta`.
  Future<void> _runSeeds() async {
    final version = await _seedVersion();
    if (version < 1) {
      await _seedProviderDefaults();
      await _setSeedVersion(1);
    }
  }

  Future<int> _seedVersion() async {
    final rows = await customSelect(
      "SELECT value FROM app_meta WHERE key = 'seed_version'",
    ).get();
    return rows.isEmpty ? 0 : int.tryParse(rows.single.read<String>('value')) ?? 0;
  }

  Future<void> _setSeedVersion(int version) => into(appMeta)
      .insertOnConflictUpdate(AppMetaRow(key: 'seed_version', value: '$version'));

  /// Seed v1: default AI provider rows for the signed-out (`local`) scope,
  /// mirroring the settings-screen provider lists (§5.3, §18). Disabled by
  /// default — "configured" only after the user saves a real configuration.
  Future<void> _seedProviderDefaults() async {
    const defaults = <({String id, String kind, String provider})>[
      (id: 'local-stt-openai_whisper', kind: 'stt', provider: 'openai_whisper'),
      (id: 'local-stt-deepgram', kind: 'stt', provider: 'deepgram'),
      (id: 'local-stt-custom', kind: 'stt', provider: 'custom'),
      (id: 'local-llm-openai', kind: 'llm', provider: 'openai'),
      (id: 'local-llm-anthropic', kind: 'llm', provider: 'anthropic'),
      (id: 'local-llm-ollama', kind: 'llm', provider: 'ollama'),
      (id: 'local-llm-custom', kind: 'llm', provider: 'custom'),
    ];
    for (final d in defaults) {
      await into(providerSettings).insert(
        ProviderSettingRow(
          id: d.id,
          userId: 'local',
          kind: d.kind,
          provider: d.provider,
          enabled: false,
        ),
        mode: InsertMode.insertOrIgnore,
      );
    }
  }

  /// Schema v6 search index (architecture §5.3 — "FTS5 over
  /// titles/summary/transcript/items/entities"). `search_fts` is an FTS5
  /// external-content virtual table over the `search_content` table; triggers
  /// on `sessions`/`topics`/`items` keep both in sync so search never drifts
  /// from the content tables. Called from `onCreate` (fresh DB) and
  /// `onUpgrade` (v5 → v6, with `search_content` created first).
  Future<void> _createSearchIndex() async {
    await customStatement(
        'CREATE VIRTUAL TABLE search_fts USING fts5(content, content=\'search_content\', content_rowid=\'rowid\')');
    // Sessions: recompute the whole aggregated row on any change.
    await customStatement('''
CREATE TRIGGER search_sess_ai AFTER INSERT ON sessions BEGIN
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('new.id')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = new.id;
END''');
    await customStatement('''
CREATE TRIGGER search_sess_au AFTER UPDATE ON sessions BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = old.id;
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('new.id')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = new.id;
END''');
    await customStatement('''
CREATE TRIGGER search_sess_ad AFTER DELETE ON sessions BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = old.id;
  DELETE FROM search_content WHERE session_id = old.id;
END''');
    // Topics: any topic change affects the whole session's aggregated content.
    await customStatement('''
CREATE TRIGGER search_topic_ai AFTER INSERT ON topics BEGIN
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('new.session_id')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = new.session_id;
END''');
    await customStatement('''
CREATE TRIGGER search_topic_au AFTER UPDATE ON topics BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = old.session_id;
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('new.session_id')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = new.session_id;
END''');
    await customStatement('''
CREATE TRIGGER search_topic_ad AFTER DELETE ON topics BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = old.session_id;
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('old.session_id')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = old.session_id;
END''');
    // Items: an item change recomputes its topic's session.
    await customStatement('''
CREATE TRIGGER search_item_ai AFTER INSERT ON items BEGIN
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('(SELECT session_id FROM topics WHERE id = new.topic_id)')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = (SELECT session_id FROM topics WHERE id = new.topic_id);
END''');
    await customStatement('''
CREATE TRIGGER search_item_au AFTER UPDATE ON items BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = (SELECT session_id FROM topics WHERE id = old.topic_id);
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('(SELECT session_id FROM topics WHERE id = new.topic_id)')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = (SELECT session_id FROM topics WHERE id = new.topic_id);
END''');
    await customStatement('''
CREATE TRIGGER search_item_ad AFTER DELETE ON items BEGIN
  INSERT INTO search_fts(search_fts, rowid, content) SELECT 'delete', rowid, content FROM search_content WHERE session_id = (SELECT session_id FROM topics WHERE id = old.topic_id);
  INSERT INTO search_content(session_id, content) ${_searchContentSelect('(SELECT session_id FROM topics WHERE id = old.topic_id)')} ON CONFLICT(session_id) DO UPDATE SET content = excluded.content;
  INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content WHERE session_id = (SELECT session_id FROM topics WHERE id = old.topic_id);
END''');
  }

  /// Searchable-content assembly for one session (architecture §5.3): session
  /// fields + all topic titles + all item titles/descriptions, concatenated.
  /// [idExpr] is a SQL expression resolving to the affected session id (e.g.
  /// `new.id` in a sessions trigger, or a subquery for topics/items triggers).
  String _searchContentSelect(String idExpr) => '''
    SELECT s.id,
      trim(coalesce(s.title, '') || ' ' || coalesce(s.alt_titles_json, '') || ' ' ||
        coalesce(s.summary, '') || ' ' || coalesce(s.original_transcript, '') || ' ' ||
        coalesce(s.cleaned_transcript, ''))
      || ' ' || coalesce((
        SELECT group_concat(t.title || ' ' || coalesce((
          SELECT group_concat(i.title || ' ' || coalesce(i.description, ''), ' ')
          FROM items i WHERE i.topic_id = t.id), ''), ' ')
        FROM topics t WHERE t.session_id = s.id), '')
    FROM sessions s WHERE s.id = $idExpr''';

  /// Backfills the (just-created) v6 search index with every existing session,
  /// so upgrading users can search their whole library immediately. The tables
  /// are empty at this point (created moments ago in `onUpgrade`), so a plain
  /// insert is safe and duplicate-free.
  Future<void> _backfillSearchIndex() async {
    await customStatement('''
      INSERT OR REPLACE INTO search_content(session_id, content) ${_searchContentSelect('s.id')}''');
    await customStatement(
        'INSERT INTO search_fts(rowid, content) SELECT rowid, content FROM search_content');
  }
}

@DriftAccessor(tables: [Sessions, Topics, Items])
class SessionsDao extends DatabaseAccessor<AppDatabase> with _$SessionsDaoMixin {
  SessionsDao(super.db);

  Stream<List<SessionRow>> watchSessions({bool includeDeleted = false}) {
    final query = select(sessions)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]);
    if (!includeDeleted) {
      query.where((t) => t.deleted.equals(false));
    }
    return query.watch();
  }

  Future<SessionRow?> getSession(String id) =>
      (select(sessions)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<List<TopicRow>> getTopics(String sessionId) {
    final q = select(topics)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([(t) => OrderingTerm.asc(t.position)]);
    return q.get();
  }

  /// Ids of every locally-known session (used by the tag pull to filter joins
  /// to sessions that actually exist after tombstoning, §4.13).
  Future<Set<String>> allSessionIds() async {
    final rows = await select(sessions).get();
    return rows.map((t) => t.id).toSet();
  }

  /// Lightweight title/summary/status rows for a set of session ids (semantic
  /// search result decoration, §6.1). Skips missing ids.
  Future<Map<String, SessionMeta>> metaForIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    final rows = await (select(sessions)
          ..where((t) => t.id.isIn(ids)))
        .get();
    return {
      for (final row in rows)
        row.id: SessionMeta(
          title: row.title,
          summary: row.summary,
          status: row.status,
        ),
    };
  }

  Future<List<ItemRow>> getItemsForTopics(List<String> topicIds) {
    if (topicIds.isEmpty) return Future.value(const []);
    final q = select(items)
      ..where((t) => t.topicId.isIn(topicIds))
      ..orderBy([(t) => OrderingTerm.asc(t.position)]);
    return q.get();
  }

  Future<void> insertSession(SessionRow row) => into(sessions).insert(row);

  /// Upserts a session without touching the outbox (pull path, §4.13).
  Future<void> upsertSession(SessionRow row) =>
      into(sessions).insertOnConflictUpdate(row);

  /// Full-row update: writes every column, including nulls (e.g. clearing
  /// `audioPath`, `audioRemoteUrl`, or `lastError`). Callers pass a
  /// fully-populated session (`copyWith` preserves all fields).
  Future<void> updateSession(SessionRow row) =>
      (update(sessions)..where((t) => t.id.equals(row.id)))
          .write(row.toCompanion(false));

  Future<void> deleteSession(String id) async {
    final topicIds = (await getTopics(id)).map((t) => t.id).toList();
    await transaction(() async {
      await (delete(db.sessionTags)..where((t) => t.sessionId.equals(id))).go();
      if (topicIds.isNotEmpty) {
        await (delete(items)..where((t) => t.topicId.isIn(topicIds))).go();
      }
      await (delete(topics)..where((t) => t.sessionId.equals(id))).go();
      await (delete(sessions)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Atomically replaces a session's topics + items (architecture §3.4).
  Future<void> replaceTopics(
      String sessionId, List<({TopicRow topic, List<ItemRow> items})> tree) {
    return transaction(() async {
      final oldTopicIds = (await getTopics(sessionId)).map((t) => t.id).toList();
      if (oldTopicIds.isNotEmpty) {
        await (delete(items)..where((t) => t.topicId.isIn(oldTopicIds))).go();
      }
      await (delete(topics)..where((t) => t.sessionId.equals(sessionId))).go();
      for (final entry in tree) {
        await into(topics).insert(entry.topic);
        for (final item in entry.items) {
          await into(items).insert(item);
        }
      }
    });
  }
}

@DriftAccessor(tables: [Jobs])
class JobsDao extends DatabaseAccessor<AppDatabase> with _$JobsDaoMixin {
  JobsDao(super.db);

  Stream<JobRow?> watchJob(String id) =>
      (select(jobs)..where((t) => t.id.equals(id))).watchSingleOrNull();

  Future<JobRow?> getJob(String id) =>
      (select(jobs)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsert(JobRow row) => into(jobs).insertOnConflictUpdate(row);
}

@DriftAccessor(tables: [ProviderSettings])
class ProviderSettingsDao extends DatabaseAccessor<AppDatabase>
    with _$ProviderSettingsDaoMixin {
  ProviderSettingsDao(super.db);

  Future<List<ProviderSettingRow>> getAll() => select(providerSettings).get();

  Future<void> upsert(ProviderSettingRow row) =>
      into(providerSettings).insertOnConflictUpdate(row);

  Future<void> deleteById(String id) =>
      (delete(providerSettings)..where((t) => t.id.equals(id))).go();
}

@DriftAccessor(tables: [Tags, SessionTags])
class TagsDao extends DatabaseAccessor<AppDatabase> with _$TagsDaoMixin {
  TagsDao(super.db);

  Future<List<TagRow>> getAll() => select(tags).get();

  Future<TagRow?> getById(String id) =>
      (select(tags)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsert(TagRow row) => into(tags).insertOnConflictUpdate(row);

  Future<void> deleteById(String id) {
    return transaction(() async {
      await (delete(sessionTags)..where((t) => t.tagId.equals(id))).go();
      await (delete(tags)..where((t) => t.id.equals(id))).go();
    });
  }

  /// Tags attached to a session (join through `session_tags`).
  Future<List<TagRow>> getTagsForSession(String sessionId) async {
    final query = select(tags).join([
      innerJoin(sessionTags, sessionTags.tagId.equalsExp(tags.id)),
    ])
      ..where(sessionTags.sessionId.equals(sessionId))
      ..orderBy([OrderingTerm.asc(tags.name)]);
    final rows = await query.get();
    return rows.map((r) => r.readTable(tags)).toList();
  }

  Stream<List<TagRow>> watchTagsForSession(String sessionId) {
    final query = select(tags).join([
      innerJoin(sessionTags, sessionTags.tagId.equalsExp(tags.id)),
    ])
      ..where(sessionTags.sessionId.equals(sessionId))
      ..orderBy([OrderingTerm.asc(tags.name)]);
    return query.watch().map(
        (rows) => rows.map((r) => r.readTable(tags)).toList());
  }

  Future<void> attachTag(String sessionId, String tagId) => into(sessionTags)
      .insert(
        SessionTagRow(sessionId: sessionId, tagId: tagId),
        mode: InsertMode.insertOrIgnore,
      );

  Future<void> detachTag(String sessionId, String tagId) =>
      (delete(sessionTags)
            ..where((t) =>
                t.sessionId.equals(sessionId) & t.tagId.equals(tagId)))
          .go();

  /// Replaces a session's full tag set atomically.
  Future<void> setSessionTags(String sessionId, List<String> tagIds) {
    return transaction(() async {
      await (delete(sessionTags)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      for (final tagId in tagIds) {
        await into(sessionTags).insert(
          SessionTagRow(sessionId: sessionId, tagId: tagId),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }
}

@DriftAccessor(tables: [Entities, SessionEntities, Relationships])
class GraphDao extends DatabaseAccessor<AppDatabase> with _$GraphDaoMixin {
  GraphDao(super.db);

  Future<List<EntityRow>> getEntities() => select(entities).get();

  Future<List<RelationshipRow>> getRelations() =>
      (select(relationships)..where((t) => t.deleted.equals(false))).get();

  /// The nodes belonging to one session (architecture §4.8 subgraph).
  Future<List<EntityRow>> entitiesForSession(String sessionId) {
    final query = select(entities).join([
      innerJoin(sessionEntities, sessionEntities.entityId.equalsExp(entities.id)),
    ])
      ..where(sessionEntities.sessionId.equals(sessionId))
      ..orderBy([OrderingTerm.asc(entities.name)]);
    return query.map((row) => row.readTable(entities)).get();
  }

  /// Confidence per node for one session.
  Future<Map<String, double>> sessionConfidence(String sessionId) async {
    final memberships =
        await (select(sessionEntities)
              ..where((t) => t.sessionId.equals(sessionId)))
            .get();
    return {
      for (final m in memberships)
        if (m.confidence != null) m.entityId: m.confidence!,
    };
  }

  /// Whether the session has any graph membership (cheap existence probe used
  /// to skip rewrites of graph-less sessions).
  Future<bool> sessionHasGraph(String sessionId) async {
    final q = selectOnly(sessionEntities)
      ..addColumns([sessionEntities.entityId])
      ..where(sessionEntities.sessionId.equals(sessionId))
      ..limit(1);
    return (await q.get()).isNotEmpty;
  }

  /// A session's live edges: owned by the session with both endpoints in the
  /// session (dangling edges are pruned on write, so this is the stored set).
  Future<List<RelationshipRow>> relationsForSession(String sessionId) async {
    final membership =
        await (select(sessionEntities)
              ..where((t) => t.sessionId.equals(sessionId)))
            .get();
    final ids = membership.map((m) => m.entityId).toSet();
    final rows = await (select(relationships)
          ..where((t) =>
              t.sessionId.equals(sessionId) & t.deleted.equals(false)))
        .get();
    return [
      for (final r in rows)
        if (ids.contains(r.sourceId) && ids.contains(r.targetId)) r,
    ];
  }

  Future<void> upsertEntity(EntityRow row) =>
      into(entities).insertOnConflictUpdate(row);

  Future<void> upsertRelation(RelationshipRow row) =>
      into(relationships).insertOnConflictUpdate(row);

  /// Atomically replaces a session's subgraph: node rows upserted, membership
  /// and owned edges replaced, then dangling edges and orphaned nodes pruned.
  Future<void> replaceSubgraph(
    String sessionId,
    List<EntityRow> nodes,
    Map<String, double?> confidence,
    List<RelationshipRow> edges,
  ) {
    return transaction(() async {
      for (final node in nodes) {
        await into(entities).insertOnConflictUpdate(node);
      }
      await (delete(sessionEntities)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      for (final node in nodes) {
        await into(sessionEntities).insertOnConflictUpdate(SessionEntityRow(
          sessionId: sessionId,
          entityId: node.id,
          confidence: confidence[node.id],
        ));
      }
      await (delete(relationships)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      for (final edge in edges) {
        await into(relationships).insertOnConflictUpdate(edge);
      }
      // Prune dangling edges whose endpoints no longer exist anywhere.
      final aliveIds = selectOnly(entities)..addColumns([entities.id]);
      final alive = await aliveIds
          .get()
          .then((rows) => rows.map((r) => r.read(entities.id)).toSet());
      final all = await (select(relationships)
            ..where((t) => t.deleted.equals(false)))
          .get();
      for (final edge in all) {
        if (!alive.contains(edge.sourceId) || !alive.contains(edge.targetId)) {
          await (delete(relationships)
                ..where((t) => t.id.equals(edge.id)))
              .go();
        }
      }
      // Prune orphaned nodes (not referenced by any session membership).
      final referencedIds = selectOnly(sessionEntities)
        ..addColumns([sessionEntities.entityId]);
      final referenced = await referencedIds
          .get()
          .then((rows) => rows
              .map((r) => r.read(sessionEntities.entityId))
              .whereType<String>()
              .toSet());
      final orphans = await (select(entities)
            ..where((t) => t.id.isNotIn(referenced)))
          .get();
      for (final orphan in orphans) {
        await (delete(entities)..where((t) => t.id.equals(orphan.id))).go();
      }
    });
  }

  /// Breadth-first traversal of the non-deleted graph from [rootId], bounded
  /// by [maxDepth] hops (§4.8 graph traversal).
  Future<List<EntityRow>> traverse(String rootId, {int maxDepth = 3}) async {
    if (maxDepth <= 0) return const [];
    final all = await (select(relationships)
          ..where((t) => t.deleted.equals(false)))
        .get();
    final visited = <String>{rootId};
    for (var depth = 0; depth < maxDepth; depth++) {
      final next = <String>[];
      for (final edge in all) {
        if (visited.contains(edge.sourceId) &&
            !visited.contains(edge.targetId)) {
          if (!next.contains(edge.targetId)) next.add(edge.targetId);
        } else if (visited.contains(edge.targetId) &&
            !visited.contains(edge.sourceId)) {
          if (!next.contains(edge.sourceId)) next.add(edge.sourceId);
        }
      }
      if (next.isEmpty) break;
      visited.addAll(next);
    }
    if (visited.length == 1) return const [];
    final query = select(entities)
      ..where((t) => t.id.isIn(visited))
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    return query.get();
  }

  Future<void> deleteEntity(String id) async {
    await transaction(() async {
      await (delete(relationships)
            ..where((t) =>
                t.sourceId.equals(id) | t.targetId.equals(id)))
          .go();
      await (delete(sessionEntities)
            ..where((t) => t.entityId.equals(id)))
          .go();
      await (delete(entities)..where((t) => t.id.equals(id))).go();
    });
  }

  Future<void> deleteRelation(String id) =>
      (delete(relationships)..where((t) => t.id.equals(id))).go();
}

@DriftAccessor(tables: [SessionVersions])
class VersionsDao extends DatabaseAccessor<AppDatabase> with _$VersionsDaoMixin {
  VersionsDao(super.db);

  Future<List<SessionVersionRow>> forSession(String sessionId) {
    final q = select(sessionVersions)
      ..where((t) => t.sessionId.equals(sessionId))
      ..orderBy([(t) => OrderingTerm.desc(t.versionNo)]);
    return q.get();
  }

  Future<int> nextVersion(String sessionId) async {
    final q = selectOnly(sessionVersions)
      ..addColumns([sessionVersions.versionNo.max()])
      ..where(sessionVersions.sessionId.equals(sessionId));
    final row = await q.getSingle();
    return (row.read(sessionVersions.versionNo.max()) ?? 0) + 1;
  }

  Future<void> insert(SessionVersionRow row) =>
      into(sessionVersions).insert(row);
}

@DriftAccessor(tables: [SyncOutbox, SyncState])
class SyncDao extends DatabaseAccessor<AppDatabase> with _$SyncDaoMixin {
  SyncDao(super.db);

  Future<void> enqueue(SyncOutboxRow row) => into(syncOutbox).insert(row);

  /// Oldest-first pending records, bounded for one drain pass.
  Future<List<SyncOutboxRow>> peekPending({int limit = 50}) {
    final q = select(syncOutbox)
      ..where((t) => t.status.equals('pending'))
      ..orderBy([(t) => OrderingTerm.asc(t.createdAt)])
      ..limit(limit);
    return q.get();
  }

  Future<int> pendingCount() {
    final q = selectOnly(syncOutbox)
      ..addColumns([syncOutbox.id.count()])
      ..where(syncOutbox.status.equals('pending'));
    return q.getSingle().then((r) => r.read(syncOutbox.id.count()) ?? 0);
  }

  Future<void> markProcessed(String id) =>
      (delete(syncOutbox)..where((t) => t.id.equals(id))).go();

  Future<void> markFailed(String id, int attempts) =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          status: const Value('failed'),
          attempts: Value(attempts),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  /// Keeps a record pending for a later pass after a transient failure.
  Future<void> retry(String id, int attempts) =>
      (update(syncOutbox)..where((t) => t.id.equals(id))).write(
        SyncOutboxCompanion(
          attempts: Value(attempts),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<DateTime?> getLastSync(String userId) async {
    final row = await (select(syncState)..where((t) => t.userId.equals(userId)))
        .getSingleOrNull();
    // drift rehydrates DateTime columns as local wall-clock; normalize to UTC
    // so cursor comparisons against other UTC timestamps stay consistent.
    return row?.lastSyncAt.toUtc();
  }

  Future<void> saveCursor(String userId, DateTime lastSyncAt) =>
      into(syncState).insertOnConflictUpdate(
        SyncStateRow(
          userId: userId,
          lastSyncAt: lastSyncAt.toUtc(),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
}

/// Serialization helpers shared by DAOs.
String? encodeJson(Object? value) => value == null ? null : jsonEncode(value);

Map<String, dynamic>? decodeJson(String? value) =>
    value == null ? null : jsonDecode(value) as Map<String, dynamic>;

@DriftAccessor(tables: [SessionOplog])
class EditLogDao extends DatabaseAccessor<AppDatabase> with _$EditLogDaoMixin {
  EditLogDao(super.db);

  Future<SessionOplogRow?> get(String sessionId) =>
      (select(sessionOplog)..where((t) => t.sessionId.equals(sessionId)))
          .getSingleOrNull();

  Future<void> save(SessionOplogRow row) =>
      into(sessionOplog).insertOnConflictUpdate(row);

  Future<void> remove(String sessionId) =>
      (delete(sessionOplog)..where((t) => t.sessionId.equals(sessionId))).go();
}

@DriftAccessor(tables: [SyncConflicts])
class SyncConflictDao extends DatabaseAccessor<AppDatabase>
    with _$SyncConflictDaoMixin {
  SyncConflictDao(super.db);

  Future<List<SyncConflictRow>> forSession(String sessionId) =>
      (select(syncConflicts)..where((t) => t.sessionId.equals(sessionId))).get();

  Future<void> insert(SyncConflictRow row) => into(syncConflicts).insert(row);

  Future<void> clearForSession(String sessionId) =>
      (delete(syncConflicts)..where((t) => t.sessionId.equals(sessionId))).go();
}

/// Raw search over the schema v6 FTS index (architecture §5.3). The index is
/// maintained by triggers, so results are always current with the content
/// tables. Matches are ranked by FTS5 `bm25` and the snippet carries
/// `\x01`/`\x02` markers around the matched terms for UI highlighting.
@DriftAccessor(tables: [Sessions, SearchContent])
class SearchDao extends DatabaseAccessor<AppDatabase> with _$SearchDaoMixin {
  SearchDao(super.db);

  /// FTS5 query for a user string: each whitespace token becomes a quoted
  /// prefix term joined with `AND`. Quoting neutralizes FTS5 query syntax so a
  /// malformed/typed query can never break the statement.
  static String toFtsQuery(String raw) {
    final tokens = raw
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll('"', ' ').trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return '';
    return tokens.map((t) => '"$t"*').join(' AND ');
  }

  Future<List<SearchHit>> search(String raw) async {
    final query = toFtsQuery(raw);
    if (query.isEmpty) return const [];
    final rows = await customSelect(
      '''
      SELECT s.id AS session_id, s.title AS title, s.summary AS summary,
             s.status AS status,
             bm25(search_fts) AS rank,
             snippet(search_fts, 0, char(1), char(2), ' … ', 14) AS snippet
      FROM search_fts f
      JOIN search_content sc ON sc.rowid = f.rowid
      JOIN sessions s ON s.id = sc.session_id
      WHERE search_fts MATCH ? AND s.deleted = 0
      ORDER BY bm25(search_fts)
      LIMIT 50
      ''',
      variables: [Variable.withString(query)],
    ).get();
    return [
      for (final row in rows)
        SearchHit(
          sessionId: row.read<String>('session_id'),
          title: row.read<String?>('title'),
          summary: row.read<String?>('summary'),
          status: row.read<String?>('status') ?? 'recording',
          rank: row.read<double>('rank'),
          snippet: row.read<String?>('snippet'),
        ),
    ];
  }
}

/// One ranked search hit (architecture §5.3). [snippet] carries the matched
/// terms wrapped in `\x01`/`\x02` markers for UI highlighting.
class SearchHit {
  const SearchHit({
    required this.sessionId,
    required this.title,
    required this.summary,
    required this.status,
    required this.rank,
    required this.snippet,
  });

  final String sessionId;
  final String? title;
  final String? summary;
  final String status;
  final double rank;
  final String? snippet;
}

/// Title/summary/status decoration for a session id (semantic search §6.1).
class SessionMeta {
  const SessionMeta({
    required this.title,
    required this.summary,
    required this.status,
  });

  final String? title;
  final String? summary;
  final String status;
}

/// AI command drafts (schema v8, architecture §4.11, spec §23): one row per
/// editable command output. Drafts are local-only until the user saves them
/// into a session, so this DAO has no sync/op-log wiring.
@DriftAccessor(tables: [Drafts])
class DraftDao extends DatabaseAccessor<AppDatabase> with _$DraftDaoMixin {
  DraftDao(super.db);

  Stream<List<DraftRow>> watchDrafts(String sessionId) =>
      (select(drafts)..where((t) => t.sessionId.equals(sessionId)))
          .watch();

  Future<DraftRow?> getDraft(String id) =>
      (select(drafts)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsert(DraftRow row) =>
      into(drafts).insertOnConflictUpdate(row);

  Future<void> deleteDraft(String id) =>
      (delete(drafts)..where((t) => t.id.equals(id))).go();
}

/// Per-session AI chat messages (schema v9, architecture §4.11, spec §17).
@DriftAccessor(tables: [ChatMessages])
class ChatDao extends DatabaseAccessor<AppDatabase> with _$ChatDaoMixin {
  ChatDao(super.db);

  Stream<List<ChatMessageRow>> watchMessages(String sessionId) =>
      (select(chatMessages)
            ..where((t) => t.sessionId.equals(sessionId))
            ..orderBy([(t) => OrderingTerm.asc(t.createdAt)]))
          .watch();

  Future<void> upsert(ChatMessageRow row) =>
      into(chatMessages).insertOnConflictUpdate(row);

  Future<void> clearForSession(String sessionId) =>
      (delete(chatMessages)..where((t) => t.sessionId.equals(sessionId))).go();
}
