import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'editing/conflict_resolver.dart';
import 'editing/oplog_diff.dart';
import 'entities/chat_message.dart';
import 'entities/command_draft.dart';
import 'entities/enums.dart';
import 'entities/graph.dart';
import 'entities/job.dart';
import 'entities/plugin.dart';
import 'entities/provider_setting.dart';
import 'entities/search_result.dart';
import 'entities/session.dart';
import 'entities/session_version.dart';
import 'entities/tag.dart';
import 'editing/operation_log.dart';
import 'entities/semantic_search_result.dart';

/// Typed application failures surfaced to the UI as user-friendly messages.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

class LocalDbFailure extends AppFailure {
  const LocalDbFailure(super.message, {super.cause});
}

class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.cause});
}

class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.cause});
}

class EngineFailure extends AppFailure {
  const EngineFailure(super.message, {super.cause});
}

class RecordingFailure extends AppFailure {
  const RecordingFailure(super.message, {super.cause});
}

class ProviderConfigFailure extends AppFailure {
  const ProviderConfigFailure(super.message, {super.cause});
}

/// Repository interfaces live in Domain; implementations live in Data
/// (architecture §3.2 dependency rule).
abstract interface class SessionRepository {
  Stream<List<Session>> watchSessions({bool includeDeleted = false});
  Future<Session?> getSession(String id);
  Future<Session> insertSession(Session session);

  /// Persists a session. With [emitDiff] the mutation is recorded as an
  /// op-log diff (§4.13 "diffs, not documents") instead of a full document.
  Future<void> updateSession(Session session, {bool emitDiff = false});

  Future<void> deleteSession(String id);

  /// Replaces a session's full knowledge tree (topics + items).
  Future<void> replaceTopics(String sessionId, List<Topic> topics);
  Future<List<Topic>> getTopics(String sessionId);
}

abstract interface class SyncRepository {
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  });

  /// Fetches a single session's current cloud state (topics + items), or null
  /// when it does not exist remotely. Used by the diff sync path to resolve
  /// conflicts against the authoritative remote base (§4.13).
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  });

  Future<void> pushSession(Session session);

  /// Marks a session deleted on the cloud (tombstone, §4.13). Pulls surface it
  /// as `deleted` so the local copy is cleaned up everywhere.
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  });
  Future<void> uploadAudio(String sessionId, String localPath);

  /// Tags + session-tag joins (architecture §7.2, spec §19). Pushed through
  /// the same write-through outbox; pulled as a full refresh (tag cardinality
  /// is small and the tables carry no per-row cursor).
  Future<void> pushTag(Tag tag);
  Future<void> deleteTag({required String userId, required String tagId});
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  });
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  });
  Future<List<Tag>> pullTags(String userId);
  Future<List<SessionTag>> pullSessionTags(String userId);
}

abstract interface class JobRepository {
  Future<Job?> getJob(String id);
  Future<Job> insertJob(Job job);
  Future<void> updateJob(Job job);
  Stream<Job?> watchJob(String id);
}

/// Persisted per-session operation log (architecture §3.4, §5.3). The log is
/// the single mutation path: every edit records here so undo/redo survives
/// restarts and outbox diffs can be emitted.
///
/// The sync layer consumes [getPendingDiff] (the lossless base + unsynced
/// batches), resolves it against the cloud, pushes the merged state, then
/// calls [markSynced] so the watermark advances and the next diff is measured
/// from the new base (architecture §4.13).
abstract interface class EditLogRepository {
  Future<OperationLog?> getLog(String sessionId);

  /// Persists [log]. [diffBase] is the session state *before* the mutation; it
  /// becomes the diff base snapshot when the log transitions from synced-clean
  /// to having unsynced edits.
  Future<void> saveLog(String sessionId, OperationLog log, {Session? diffBase});

  /// The pending lossless diff for a session, or null when nothing is
  /// unsynced. The diff's base is the session state at the sync watermark.
  Future<OplogDiff?> getPendingDiff(String sessionId);

  /// Advances the sync watermark to the current cursor and records [base] (the
  /// pushed, converged session) as the new diff base.
  Future<void> markSynced(String sessionId, {required Session base});
}

/// Flagged sync conflicts, persisted for user review (architecture §4.13).
abstract interface class ConflictRepository {
  Future<void> addAll(String sessionId, List<SessionConflict> conflicts);
  Future<List<SessionConflict>> forSession(String sessionId);
  Future<void> clear(String sessionId);
}

/// Version history storage (architecture §4.6, §5.3 `session_versions`).
abstract interface class VersionRepository {
  /// All versions for a session, oldest first (version_no ascending).
  Future<List<SessionVersion>> getVersions(String sessionId);
  Future<SessionVersion> commit(SessionVersion version);
  Future<SessionVersion?> getVersion(String sessionId, int versionNo);
}

abstract interface class ProviderSettingsRepository {
  Future<List<ProviderSetting>> getAll();
  Future<void> save(ProviderSetting setting);
  Future<void> delete(String id);
}

abstract interface class TagRepository {
  Future<List<Tag>> getAll();

  /// Tags attached to a session (architecture §5.3 `session_tags`).
  Future<List<Tag>> getTagsForSession(String sessionId);
  Stream<List<Tag>> watchTagsForSession(String sessionId);

  Future<void> save(Tag tag);
  Future<void> delete(String id);

  /// Attaches/detaches a tag on a session. Idempotent.
  Future<void> attachTag({required String sessionId, required String tagId});
  Future<void> detachTag({required String sessionId, required String tagId});

  /// Replaces a session's full tag set.
  Future<void> setSessionTags(String sessionId, List<String> tagIds);
}

abstract interface class GraphRepository {
  Future<List<GraphEntity>> getEntities();
  Future<List<GraphRelation>> getRelations();

  /// The knowledge subgraph for one session: its nodes + their edges
  /// (architecture §4.8).
  Future<SessionGraph> getSubgraph(String sessionId);

  /// Breadth-first traversal of the user's graph starting at [rootId],
  /// bounded by [maxDepth] hops (§4.8 graph traversal).
  Future<List<GraphEntity>> traverse(String rootId, {int maxDepth = 3});

  /// Session ids that mention [entityId] (global graph browse, §6.2): every
  /// session whose subgraph membership includes the entity.
  Future<List<String>> sessionIdsForEntity(String entityId);

  Future<void> saveEntity(GraphEntity entity);
  Future<void> saveRelation(GraphRelation relation);

  /// Atomically replaces a session's subgraph (membership, node rows, edges)
  /// and prunes orphaned nodes + dangling edges.
  Future<void> replaceSubgraph(String sessionId, SessionGraph graph);

  Future<void> deleteEntity(String id);
  Future<void> deleteRelation(String id);
}

/// Full-text search over sessions + content (architecture §5.3). Implemented
/// locally over FTS5 (schema v6), with an optional cloud fallback when the
/// local index misses (§5.4 "cloud-side FTS fallback").
abstract interface class SearchRepository {
  Future<List<SearchResult>> search(String query);
}

/// On-device embedding persistence + similarity search (architecture §5.3,
/// §6.1). Vectors live in the drift `embeddings` table as float32 blobs and
/// are ranked in Dart with `vector_codec.dart`.
abstract interface class EmbeddingRepository {
  Future<void> upsertSessionEmbedding({
    required String sessionId,
    required String scope,
    required String contentRef,
    required List<double> vector,
  });

  Future<List<double>?> embeddingForSession(String sessionId);

  /// Session ids that completed analysis (ready/edited/synced) but have no
  /// `local` embedding yet — the §6.1 backfill candidate set. Sessions created
  /// after the `embedding` stage shipped already persist a vector during
  /// analysis; older ones need the engine to embed their content on demand.
  Future<List<String>> sessionsWithoutLocalEmbedding();

  Future<void> deleteSessionEmbeddings(String sessionId);

  /// Sessions ranked by cosine similarity to [queryVector], filtered by
  /// [threshold], capped at [limit], excluding [excludeSessionId].
  Future<List<SemanticSearchResult>> searchSimilar(
    List<double> queryVector, {
    int limit = 20,
    double threshold = 0.7,
    String? excludeSessionId,
  });
}

/// Hybrid semantic search (architecture §5.4, §6.1): the query is embedded by
/// the engine (`POST /api/v1/search/semantic`); the returned query embedding
/// ranks locally-stored vectors while the engine's pgvector results fill in
/// sessions missing locally. Results are merged, deduped and sorted by
/// similarity.
abstract interface class SemanticSearchRepository {
  Future<List<SemanticSearchResult>> search(
    String query, {
    int limit = 20,
  });
}

/// AI command drafts (architecture §4.11, spec §23). Drafts are the editable
/// outputs of the AI command bus; they live locally and ride no sync/op-log
/// path until the user saves them into a session.
abstract interface class DraftRepository {
  Stream<List<CommandDraft>> watchDrafts(String sessionId);
  Future<CommandDraft?> getDraft(String id);
  Future<CommandDraft> saveDraft(CommandDraft draft);
  Future<void> deleteDraft(String id);
}

/// Per-session AI chat history (architecture §4.11, spec §17). Local-only:
/// messages ride no sync/op-log path. User questions are persisted before the
/// job runs; assistant answers land here on job success.
abstract interface class ChatRepository {
  Stream<List<ChatMessage>> watchMessages(String sessionId);
  Future<void> addMessage(ChatMessage message);
}

/// Per-user privacy preferences (spec §18, architecture §12). Stored locally
/// in `app_meta`, keyed per user id.
abstract interface class AppSettingsRepository {
  /// "Delete audio after processing": when on, the raw recording file is
  /// removed as soon as its session finishes analysis.
  Future<bool> getDeleteAudioAfterProcessing(String userId);
  Future<void> setDeleteAudioAfterProcessing(String userId, bool value);

  /// "Cross-session insights" (opt-in, architecture §4.9, §12): when on, the
  /// app ships compact session descriptors to the engine so it can compute
  /// insight statements. Off by default.
  Future<bool> getEnableInsights(String userId);
  Future<void> setEnableInsights(String userId, bool value);

  /// "AI memory" (opt-in, architecture §4.9, §12): when on, the app ships a
  /// compact, token-budgeted block of related-session context with analysis
  /// and chat jobs so the engine can reason across sessions. Off by default.
  Future<bool> getEnableMemory(String userId);
  Future<void> setEnableMemory(String userId, bool value);

  /// Per-session memory skip: when on, no memory context is built for this
  /// session (architecture §4.9 "skip-able per session").
  Future<bool> getMemorySkip(String sessionId);
  Future<void> setMemorySkip(String sessionId, bool value);
}

/// Engine client contract (architecture §7.1). Implementation lives in
/// `data/engine`.
abstract interface class EngineGateway {
  Future<Job> createJob({
    required String userId,
    required JobKind kind,
    String? inputRef,
    Map<String, dynamic>? options,
    Map<String, dynamic>? promptVersions,
  });

  Future<Job> getJob(String userId, String jobId);

  Future<void> cancelJob(String userId, String jobId);

  Stream<Job> streamJob(String userId, String jobId);

  /// Semantic search over sessions (architecture §5.4, §6.1). Embeds [query]
  /// and returns pgvector results plus the query embedding for local ranking.
  Future<EngineSemanticSearch> semanticSearch(
    String query, {
    int limit = 20,
    double threshold = 0.7,
  });

  /// Embeds session content for local-index backfill (§6.1): sessions analyzed
  /// before the `embedding` stage shipped have no on-device vector, so the app
  /// sends their text and stores the returned vectors locally. The engine is
  /// the only place AI models run (architecture §2).
  Future<EngineEmbedSessions> embedSessions(
    List<({String sessionId, String text})> sessions, {
    int limit = 50,
  });

  /// Connection status of every registered plugin target (architecture §4.11).
  Future<List<PluginTargetStatus>> listPlugins(String userId);

  /// Starts OAuth2 for a plugin target; returns the authorization URL and the
  /// engine-side state that must be echoed back on token exchange.
  Future<PluginAuthUrl> pluginAuthUrl(
    String userId,
    String kind, {
    required String redirectUri,
  });

  /// Exchanges the OAuth2 authorization code for stored server-side
  /// credentials. `state` must match what `pluginAuthUrl` returned.
  Future<void> exchangePluginToken(
    String userId,
    String kind, {
    required String code,
    required String state,
    required String redirectUri,
  });

  /// Pushes a command draft to a connected plugin target.
  Future<PluginPushReceipt> pushDraft(
    String userId,
    String kind, {
    required Map<String, dynamic> draft,
    String? target,
  });

  /// Disconnects (revokes) a plugin target's stored credentials.
  Future<void> disconnectPlugin(String userId, String kind);
}

/// Secure key-value storage (API keys, auth session). Implementation in
/// `core/secure_storage`.
abstract interface class SecureStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}

/// Auth repository, implemented in `features/auth`.
abstract interface class AuthRepository {
  Stream<String?> watchUserId();
  String? get currentUserId;
  Future<void> signInWithGoogle();
  Future<void> signOut();
}

/// Database provider for tests and injection.
final databaseProvider = Provider<SessionRepository>((ref) {
  throw UnimplementedError('SessionRepository provider must be overridden');
});

final editLogRepositoryProvider = Provider<EditLogRepository>((ref) {
  throw UnimplementedError('EditLogRepository provider must be overridden');
});

final conflictRepositoryProvider = Provider<ConflictRepository>((ref) {
  throw UnimplementedError('ConflictRepository provider must be overridden');
});

final versionRepositoryProvider = Provider<VersionRepository>((ref) {
  throw UnimplementedError('VersionRepository provider must be overridden');
});

final syncProvider = Provider<SyncRepository>((ref) {
  throw UnimplementedError('SyncRepository provider must be overridden');
});

final jobProvider = Provider<JobRepository>((ref) {
  throw UnimplementedError('JobRepository provider must be overridden');
});

final providerSettingsRepositoryProvider = Provider<ProviderSettingsRepository>((ref) {
  throw UnimplementedError('ProviderSettingsRepository provider must be overridden');
});

final tagRepositoryProvider = Provider<TagRepository>((ref) {
  throw UnimplementedError('TagRepository provider must be overridden');
});

final graphRepositoryProvider = Provider<GraphRepository>((ref) {
  throw UnimplementedError('GraphRepository provider must be overridden');
});

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  throw UnimplementedError('SearchRepository provider must be overridden');
});

final embeddingRepositoryProvider = Provider<EmbeddingRepository>((ref) {
  throw UnimplementedError('EmbeddingRepository provider must be overridden');
});

final semanticSearchRepositoryProvider =
    Provider<SemanticSearchRepository>((ref) {
  throw UnimplementedError(
      'SemanticSearchRepository provider must be overridden');
});

final draftRepositoryProvider = Provider<DraftRepository>((ref) {
  throw UnimplementedError('DraftRepository provider must be overridden');
});

final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  throw UnimplementedError('ChatRepository provider must be overridden');
});

final engineGatewayProvider = Provider<EngineGateway>((ref) {
  throw UnimplementedError('EngineGateway provider must be overridden');
});

final appSettingsRepositoryProvider = Provider<AppSettingsRepository>((ref) {
  throw UnimplementedError('AppSettingsRepository provider must be overridden');
});

final secureStoreProvider = Provider<SecureStore>((ref) {
  throw UnimplementedError('SecureStore provider must be overridden');
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  throw UnimplementedError('AuthRepository provider must be overridden');
});
