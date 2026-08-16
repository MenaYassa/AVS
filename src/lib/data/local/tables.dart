import 'package:drift/drift.dart';

/// Drift schema v2 (architecture §5.3). v2 adds the sync outbox + cursor
/// tables for the write-through sync engine (§4.13).

/// A pending write destined for the cloud (architecture §4.13).
///
/// Mutations write to SQLite immediately and enqueue a record here; the sync
/// engine drains it after auth. `op` is `upsert` or `delete`.
@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get entityType => text().named('entity_type')();
  TextColumn get entityId => text().named('entity_id')();
  TextColumn get op => text()();
  TextColumn get payloadJson => text().named('payload_json').nullable()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-user sync cursor for incremental pull (`updated_at > last_sync`).
@DataClassName('SyncStateRow')
class SyncState extends Table {
  TextColumn get userId => text().named('user_id')();
  DateTimeColumn get lastSyncAt => dateTime().named('last_sync_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {userId};
}

@DataClassName('SessionRow')
class Sessions extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get title => text().nullable()();
  TextColumn get altTitlesJson => text().named('alt_titles_json').nullable()();
  TextColumn get summary => text().nullable()();
  RealColumn get summaryConfidence =>
      real().named('summary_confidence').nullable()();
  RealColumn get extractionConfidence =>
      real().named('extraction_confidence').nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('recording'))();
  RealColumn get durationSec => real().named('duration_sec').nullable()();
  IntColumn get wordCount => integer().named('word_count').nullable()();
  TextColumn get originalTranscript =>
      text().named('original_transcript').nullable()();
  TextColumn get cleanedTranscript =>
      text().named('cleaned_transcript').nullable()();
  TextColumn get audioPath => text().named('audio_path').nullable()();
  TextColumn get audioRemoteUrl => text().named('audio_remote_url').nullable()();
  TextColumn get promptVersionsJson =>
      text().named('prompt_versions_json').nullable()();
  BoolColumn get favorite => boolean().withDefault(const Constant(false))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get lastErrorJson => text().named('last_error_json').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TopicRow')
class Topics extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  IntColumn get position => integer()();
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  RealColumn get confidence => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ItemRow')
class Items extends Table {
  TextColumn get id => text()();
  TextColumn get topicId => text().named('topic_id')();
  IntColumn get position => integer()();
  TextColumn get type => text()();
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get priority => text().nullable()();
  RealColumn get timestampSec => real().named('timestamp_sec').nullable()();
  RealColumn get confidence => real().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionVersionRow')
class SessionVersions extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  IntColumn get versionNo => integer().named('version_no')();
  TextColumn get snapshotJson => text().named('snapshot_json')();
  TextColumn get promptVersionsJson =>
      text().named('prompt_versions_json').nullable()();
  TextColumn get changeReason => text().named('change_reason').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('TagRow')
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionTagRow')
class SessionTags extends Table {
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get tagId => text().named('tag_id')();

  @override
  Set<Column> get primaryKey => {sessionId, tagId};
}

@DataClassName('EntityRow')
class Entities extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get type => text()();
  TextColumn get name => text()();
  TextColumn get canonicalName => text().named('canonical_name').nullable()();
  TextColumn get aliasesJson => text().named('aliases_json').nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SessionEntityRow')
class SessionEntities extends Table {
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get entityId => text().named('entity_id')();
  RealColumn get confidence => real().nullable()();

  @override
  Set<Column> get primaryKey => {sessionId, entityId};
}

@DataClassName('RelationshipRow')
class Relationships extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get sourceId => text().named('source_id')();
  TextColumn get targetId => text().named('target_id')();
  TextColumn get type => text()();
  RealColumn get weight => real().withDefault(const Constant(1.0))();
  RealColumn get confidence => real().nullable()();
  TextColumn get sessionId => text().named('session_id').nullable()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('JobRow')
class Jobs extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get kind => text()();
  TextColumn get status => text()();
  TextColumn get stage => text().nullable()();
  TextColumn get inputRef => text().named('input_ref').nullable()();
  TextColumn get resultJson => text().named('result_json').nullable()();
  TextColumn get errorJson => text().named('error_json').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ProviderSettingRow')
class ProviderSettings extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text().named('user_id')();
  TextColumn get kind => text()();
  TextColumn get provider => text()();
  TextColumn get configJson => text().named('config_json').nullable()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('EmbeddingRow')
class Embeddings extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get scope => text()();
  TextColumn get contentRef => text().named('content_ref')();
  BlobColumn get vector => blob().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Key/value app metadata (schema v3): tracks the seed version so default
/// rows are inserted exactly once per database, regardless of the path taken
/// to the current schema (fresh create or stepwise upgrade).
@DataClassName('AppMetaRow')
class AppMeta extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Per-session operation log (schema v4, architecture §3.4, §5.3). The op-log
/// is the single mutation path: undo/redo survives restarts and outbox diffs
/// can be emitted from it. The whole log (batches + cursor + sync watermark)
/// is stored as canonical JSON — one row per session. Schema v5 adds
/// `base_snapshot_json`, the session state the unsynced diff was recorded
/// against (§4.13), so the conflict resolver can translate base-relative
/// positions onto the current cloud state.
@DataClassName('SessionOplogRow')
class SessionOplog extends Table {
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get logJson => text().named('log_json')();
  TextColumn get baseSnapshotJson => text().named('base_snapshot_json').nullable()();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {sessionId};
}

/// True conflicts flagged during diff sync, kept for user review (schema v5,
/// architecture §4.13 — "field-level LWW + flagged true conflicts").
@DataClassName('SyncConflictRow')
class SyncConflicts extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get kind => text()();
  TextColumn get description => text()();
  TextColumn get fieldPath => text().named('field_path').nullable()();
  TextColumn get localValue => text().named('local_value').nullable()();
  TextColumn get remoteValue => text().named('remote_value').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}

/// Denormalized per-session search content (schema v6, architecture §5.3 —
/// "FTS5 over titles/summary/transcript/items/entities"). One row per session
/// holding every searchable field concatenated (title, alt titles, summary,
/// transcripts, topic titles, item titles + descriptions). The FTS index
/// `search_fts` is an external-content virtual table over this table's rowid,
/// maintained by triggers on `sessions`/`topics`/`items` (see `database.dart`
/// `onCreate`/`onUpgrade`), so search never drifts from the content tables.
@DataClassName('SearchContentRow')
class SearchContent extends Table {
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get content => text()();

  @override
  Set<Column> get primaryKey => {sessionId};
}

/// AI command drafts (schema v8, architecture §4.11, spec §23). One row per
/// editable command output, keyed to the session it was produced from. Items
/// and prompt provenance are stored as canonical JSON.
@DataClassName('DraftRow')
class Drafts extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get command => text()();
  TextColumn get title => text()();
  TextColumn get body => text()();
  TextColumn get itemsJson => text().named('items_json').nullable()();
  TextColumn get promptVersionsJson =>
      text().named('prompt_versions_json').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();
  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-session AI chat messages (schema v9, architecture §4.11, spec §17).
/// One row per exchange; the user's question is persisted before the job runs
/// and the engine's grounded answer lands here on job success. Citations,
/// confidence, and prompt provenance are stored as canonical JSON. Chat is
/// local-only like drafts — it rides no sync/op-log path.
@DataClassName('ChatMessageRow')
class ChatMessages extends Table {
  TextColumn get id => text()();
  TextColumn get sessionId => text().named('session_id')();
  TextColumn get role => text()();
  TextColumn get content => text()();
  TextColumn get citationsJson => text().named('citations_json').nullable()();
  RealColumn get confidence => real().nullable()();
  TextColumn get promptVersionsJson =>
      text().named('prompt_versions_json').nullable()();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}
