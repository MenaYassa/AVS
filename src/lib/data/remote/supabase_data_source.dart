import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Session;

import '../../core/logging/app_logger.dart';
import '../../domain/entities/enums.dart';
import '../../domain/entities/graph.dart';
import '../../domain/entities/search_result.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';

/// Supabase-backed auth + sync (architecture §6, §7.2).
///
/// RLS enforces `user_id = auth.uid()` on the server; the client never trusts
/// its own ownership checks (architecture §5.4).

class SupabaseAuthRepository implements AuthRepository {
  SupabaseAuthRepository(this._client, {String? serverClientId})
      : _google = GoogleSignIn(
          serverClientId: (serverClientId != null && serverClientId.isNotEmpty)
              ? serverClientId
              : (const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID').isNotEmpty
                  ? const String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID')
                  : null),
          scopes: const ['email', 'profile', 'openid'],
        );

  final SupabaseClient _client;
  final GoogleSignIn _google;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Stream<String?> watchUserId() {
    return _client.auth.onAuthStateChange.map((state) => state.session?.user.id);
  }

  @override
  Future<void> signInWithGoogle() async {
    try {
      final googleUser = await _google.signIn();
      if (googleUser == null) {
        // User cleanly dismissed / cancelled the account chooser
        return;
      }
      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthFailure(
          'Google sign-in did not return an ID token. Please ensure GOOGLE_SERVER_CLIENT_ID is configured with your OAuth Web client ID.',
        );
      }
      await _client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: googleAuth.accessToken,
      );
    } on AuthFailure {
      rethrow;
    } on AuthException catch (e, st) {
      Log.e('Supabase auth failed', e, st);
      throw AuthFailure(e.message, cause: e);
    } catch (e, st) {
      Log.e('Google sign-in failed', e, st);
      final errorMsg = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
      throw AuthFailure('Sign-in failed: $errorMsg', cause: e);
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _google.signOut();
    } catch (e) {
      Log.w('Google sign-out warning: $e');
    }
    await _client.auth.signOut();
  }
}

class SupabaseSyncRepository implements SyncRepository {
  SupabaseSyncRepository(this._client);

  final SupabaseClient _client;

  static const _sessions = 'sessions';
  static const _topics = 'topics';
  static const _items = 'items';
  static const _tags = 'tags';
  static const _sessionTags = 'session_tags';
  static const _entities = 'entities';
  static const _sessionEntities = 'session_entities';
  static const _relationships = 'relationships';

  @override
  Future<void> pushSession(Session session) async {
    // Ownership is enforced by RLS via the JWT, not by the payload (§5.4).
    // Attribute the write to the authenticated user so signed-out drafts
    // (`user_id = 'local'`) converge once the user signs in.
    final ownerId = _client.auth.currentUser?.id ?? session.userId;
    await _client.from(_sessions).upsert({
      'id': session.id,
      'user_id': ownerId,
      'title': session.title,
      'alt_titles_json': jsonEncode(session.alternativeTitles),
      'summary': session.summary,
      'summary_confidence': session.summaryConfidence,
      'extraction_confidence': session.extractionConfidence,
      'language': session.language,
      'status': session.status.name,
      'duration_sec': session.durationSec,
      'word_count': session.wordCount,
      'original_transcript': session.originalTranscript,
      'cleaned_transcript': session.cleanedTranscript,
      'audio_remote_url': session.audioRemoteUrl,
      'prompt_versions_json': jsonEncode(session.promptVersions),
      'favorite': session.favorite,
      'archived': session.archived,
      'deleted': session.deleted,
      'pinned': session.pinned,
      'created_at': session.createdAt?.toIso8601String(),
      'updated_at': session.updatedAt?.toIso8601String(),
    });

    for (final topic in session.topics) {
      await _client.from(_topics).upsert({
        'id': topic.id,
        'session_id': session.id,
        'position': topic.position,
        'title': topic.title,
        'description': topic.description,
        'confidence': topic.confidence,
      });
      for (final item in topic.items) {
        await _client.from(_items).upsert({
          'id': item.id,
          'topic_id': topic.id,
          'position': item.position,
          'type': item.type.name,
          'title': item.title,
          'description': item.description,
          'priority': item.priority?.name,
          'timestamp_sec': item.timestampSec,
          'confidence': item.confidence,
        });
      }
    }

    // Replace the session's subgraph (architecture §4.8). Entities are
    // global per user and only ever upserted; membership and edges are
    // session-owned and replaced wholesale, mirroring the local
    // `GraphDao.replaceSubgraph` semantics so a merge on the cloud converges.
    for (final entity in session.entities) {
      await _client.from(_entities).upsert({
        'id': entity.id,
        'user_id': ownerId,
        'type': entity.type.wireName,
        'name': entity.name,
        'canonical_name': entity.canonicalName,
        'aliases_json': jsonEncode(entity.aliases),
      });
    }
    await _client.from(_sessionEntities).delete().eq('session_id', session.id);
    for (final entity in session.entities) {
      await _client.from(_sessionEntities).upsert({
        'session_id': session.id,
        'entity_id': entity.id,
        'confidence': entity.confidence,
      });
    }
    await _client.from(_relationships).delete().eq('session_id', session.id);
    for (final relation in session.relationships) {
      await _client.from(_relationships).upsert({
        'id': relation.id,
        'user_id': ownerId,
        'source_id': relation.sourceId,
        'target_id': relation.targetId,
        'type': relation.type.wireName,
        'weight': relation.weight,
        'confidence': relation.confidence,
        'session_id': session.id,
      });
    }
  }

  @override
  Future<void> deleteSession({
    required String userId,
    required String sessionId,
  }) async {
    // Tombstone: keep the row so incremental pulls converge (§4.13). Scope by
    // id only — RLS's USING clause restricts the update to the JWT owner, and
    // the outbox `userId` may be the pre-auth 'local' placeholder.
    await _client
        .from(_sessions)
        .update({'deleted': true, 'updated_at': DateTime.now().toUtc().toIso8601String()})
        .eq('id', sessionId);
  }

  @override
  Future<Session?> pullSession({
    required String userId,
    required String sessionId,
  }) async {
    final res = await _client
        .from(_sessions)
        .select()
        .eq('user_id', userId)
        .eq('id', sessionId)
        .limit(1);
    final sessionRows = (res as List<dynamic>).cast<Map<String, dynamic>>();
    if (sessionRows.isEmpty) return null;
    if (sessionRows.first['deleted'] == true) return null;

    final topicRes = await _client
        .from(_topics)
        .select()
        .eq('session_id', sessionId);
    final topicRows = (topicRes as List<dynamic>).cast<Map<String, dynamic>>();
    final topicIds = topicRows.map((t) => t['id'] as String).toList();

    var itemRows = <Map<String, dynamic>>[];
    if (topicIds.isNotEmpty) {
      final itemRes =
          await _client.from(_items).select().inFilter('topic_id', topicIds);
      itemRows = (itemRes as List<dynamic>).cast<Map<String, dynamic>>();
    }

    final graph = await _pullGraph([sessionId]);

    return _sessionFromCloud(sessionRows.first, topicRows, itemRows, graph);
  }

  @override
  Future<List<Session>> pullChangedSessions({
    required String userId,
    required DateTime since,
  }) async {
    final res = await _client
        .from(_sessions)
        .select()
        .eq('user_id', userId)
        .gte('updated_at', since.toIso8601String())
        .order('updated_at', ascending: true);
    final sessionRows = (res as List<dynamic>).cast<Map<String, dynamic>>();
    if (sessionRows.isEmpty) return const [];

    final sessionIds = sessionRows.map((e) => e['id'] as String).toList();
    final topicRes = await _client
        .from(_topics)
        .select()
        .inFilter('session_id', sessionIds);
    final topicRows = (topicRes as List<dynamic>).cast<Map<String, dynamic>>();
    final topicIds = topicRows.map((t) => t['id'] as String).toList();

    var itemRows = <Map<String, dynamic>>[];
    if (topicIds.isNotEmpty) {
      final itemRes =
          await _client.from(_items).select().inFilter('topic_id', topicIds);
      itemRows = (itemRes as List<dynamic>).cast<Map<String, dynamic>>();
    }

    final graph = await _pullGraph(sessionIds);

    return sessionRows
        .map((e) => _sessionFromCloud(e, topicRows, itemRows, graph))
        .toList();
  }

  @override
  Future<void> pushTag(Tag tag) async {
    final ownerId = _client.auth.currentUser?.id ?? tag.userId;
    await _client.from(_tags).upsert({
      'id': tag.id,
      'user_id': ownerId,
      'name': tag.name,
      'color': tag.color,
    });
  }

  @override
  Future<void> deleteTag({
    required String userId,
    required String tagId,
  }) async {
    // RLS's USING clause restricts the delete to the JWT owner; `user_id`
    // scope is defense-in-depth for signed-out rows pending first sign-in.
    await _client.from(_tags).delete().eq('id', tagId).eq('user_id', userId);
  }

  @override
  Future<void> pushSessionTag({
    required String sessionId,
    required String tagId,
  }) async {
    await _client.from(_sessionTags).upsert({
      'session_id': sessionId,
      'tag_id': tagId,
    });
  }

  @override
  Future<void> deleteSessionTag({
    required String sessionId,
    required String tagId,
  }) async {
    await _client
        .from(_sessionTags)
        .delete()
        .eq('session_id', sessionId)
        .eq('tag_id', tagId);
  }

  @override
  Future<List<Tag>> pullTags(String userId) async {
    final res =
        await _client.from(_tags).select().eq('user_id', userId);
    final rows = (res as List<dynamic>).cast<Map<String, dynamic>>();
    return rows.map(Tag.fromJson).toList();
  }

  @override
  Future<List<SessionTag>> pullSessionTags(String userId) async {
    // Scoped to the JWT owner through the sessions FK (session_tags has no
    // user_id column of its own).
    final res = await _client
        .from(_sessionTags)
        .select('session_id, tag_id, sessions(user_id)')
        .eq('sessions.user_id', userId);
    final rows = (res as List<dynamic>).cast<Map<String, dynamic>>();
    return [
      for (final r in rows)
        SessionTag(
          sessionId: r['session_id'] as String,
          tagId: r['tag_id'] as String,
        ),
    ];
  }

  @override
  Future<void> uploadAudio(String sessionId, String localPath) async {
    final bytes = await File(localPath).readAsBytes();
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const AuthFailure('Cannot upload audio while signed out.');
    }
    // Object key within the `sessions` bucket. The engine consumes the
    // corresponding bucket/object reference as
    // `sessions/{user_id}/{session_id}.m4a` through its BlobFetcher.
    // Storage RLS allows each user to touch only their own first-level folder.
    final path = '$userId/$sessionId.m4a';
    await _client.storage
        .from('sessions')
        .uploadBinary(path, bytes, fileOptions: const FileOptions(upsert: true));
  }

  Session _sessionFromCloud(
    Map<String, dynamic> json,
    List<Map<String, dynamic>> topicRows,
    List<Map<String, dynamic>> itemRows,
    _CloudGraph graph,
  ) {
    final sessionTopics = topicRows.where((t) => t['session_id'] == json['id']);
    final topics = sessionTopics.map((t) {
      final items = itemRows
          .where((i) => i['topic_id'] == t['id'])
          .map(_itemFromCloud)
          .toList()
        ..sort((a, b) => a.position.compareTo(b.position));
      return Topic(
        id: t['id'] as String,
        position: (t['position'] as num?)?.toInt() ?? 0,
        title: t['title'] as String? ?? '',
        description: t['description'] as String? ?? '',
        confidence: (t['confidence'] as num?)?.toDouble(),
        items: items,
      );
    }).toList()
      ..sort((a, b) => a.position.compareTo(b.position));

    final sessionEntities = graph.entitiesBySession[json['id']] ?? const [];
    final entityIds = sessionEntities.map((e) => e.id).toSet();
    final sessionRelations = graph.relationsBySession[json['id']] ?? const [];
    final sessionRelationships = sessionRelations
        .where((r) => entityIds.contains(r.sourceId) && entityIds.contains(r.targetId))
        .toList();

    return Session(
      id: json['id'] as String,
      userId: json['user_id'] as String,
      title: json['title'] as String?,
      alternativeTitles: json['alt_titles_json'] == null
          ? const []
          : (jsonDecode(json['alt_titles_json'] as String) as List<dynamic>)
              .cast<String>(),
      summary: json['summary'] as String?,
      summaryConfidence: (json['summary_confidence'] as num?)?.toDouble(),
      extractionConfidence: (json['extraction_confidence'] as num?)?.toDouble(),
      language: json['language'] as String?,
      status: SessionStatus.values
              .where((s) => s.name == json['status'])
              .firstOrNull ??
          SessionStatus.ready,
      durationSec: (json['duration_sec'] as num?)?.toDouble(),
      wordCount: (json['word_count'] as num?)?.toInt(),
      originalTranscript: json['original_transcript'] as String?,
      cleanedTranscript: json['cleaned_transcript'] as String?,
      audioRemoteUrl: json['audio_remote_url'] as String?,
      promptVersions: json['prompt_versions_json'] == null
          ? const {}
          : (jsonDecode(json['prompt_versions_json'] as String)
              as Map<String, dynamic>),
      favorite: json['favorite'] as bool? ?? false,
      archived: json['archived'] as bool? ?? false,
      deleted: json['deleted'] as bool? ?? false,
      pinned: json['pinned'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      topics: topics,
      entities: sessionEntities,
      relationships: sessionRelationships,
    );
  }

  /// Fetches the subgraphs for a set of sessions in three batched calls and
  /// groups them by session (architecture §4.8). Soft-deleted edges are
  /// dropped so a tombstone from a merge converges locally.
  Future<_CloudGraph> _pullGraph(List<String> sessionIds) async {
    if (sessionIds.isEmpty) return const _CloudGraph();

    final joinRes = await _client
        .from(_sessionEntities)
        .select()
        .inFilter('session_id', sessionIds);
    final joinRows =
        (joinRes as List<dynamic>).cast<Map<String, dynamic>>();
    final entityIds =
        joinRows.map((j) => j['entity_id'] as String).toSet().toList();

    var entityRows = <Map<String, dynamic>>[];
    if (entityIds.isNotEmpty) {
      final entityRes =
          await _client.from(_entities).select().inFilter('id', entityIds);
      entityRows = (entityRes as List<dynamic>).cast<Map<String, dynamic>>();
    }
    final entityById = {for (final e in entityRows) e['id'] as String: e};

    final relationRes = await _client
        .from(_relationships)
        .select()
        .inFilter('session_id', sessionIds);
    final relationRows =
        (relationRes as List<dynamic>).cast<Map<String, dynamic>>();

    final entitiesBySession = <String, List<GraphEntity>>{};
    final relationsBySession = <String, List<GraphRelation>>{};
    for (final j in joinRows) {
      final sessionId = j['session_id'] as String;
      final entityId = j['entity_id'] as String;
      final row = entityById[entityId];
      if (row == null) continue;
      entitiesBySession.putIfAbsent(sessionId, () => []).add(GraphEntity(
            id: entityId,
            userId: row['user_id'] as String,
            type: EntityType.fromWire(row['type'] as String?) ??
                EntityType.concept,
            name: row['name'] as String,
            canonicalName: row['canonical_name'] as String?,
            aliases: row['aliases_json'] == null
                ? const []
                : (jsonDecode(row['aliases_json'] as String) as List<dynamic>)
                    .cast<String>(),
            confidence: (j['confidence'] as num?)?.toDouble(),
          ));
    }
    for (final r in relationRows) {
      if (r['deleted'] == true) continue;
      final sessionId = r['session_id'] as String;
      relationsBySession.putIfAbsent(sessionId, () => []).add(GraphRelation(
            id: r['id'] as String,
            userId: r['user_id'] as String,
            sourceId: r['source_id'] as String,
            targetId: r['target_id'] as String,
            type: RelationType.fromWire(r['type'] as String?) ??
                RelationType.relatedTo,
            weight: (r['weight'] as num?)?.toDouble() ?? 1.0,
            confidence: (r['confidence'] as num?)?.toDouble(),
            sessionId: sessionId,
          ));
    }
    return _CloudGraph(entitiesBySession, relationsBySession);
  }

  Item _itemFromCloud(Map<String, dynamic> json) => Item(
        id: json['id'] as String,
        type: ItemType.fromWire(json['type'] as String?) ?? ItemType.idea,
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        position: (json['position'] as num?)?.toInt() ?? 0,
        priority: Priority.fromWire(json['priority'] as String?),
        timestampSec: (json['timestamp_sec'] as num?)?.toDouble(),
        confidence: (json['confidence'] as num?)?.toDouble(),
      );
}

/// Batch-pulled graph rows, grouped by session so `_sessionFromCloud` can
/// hydrate each session's subgraph with a single pass.
class _CloudGraph {
  const _CloudGraph(
    [this.entitiesBySession = const {},
    this.relationsBySession = const {}]);

  final Map<String, List<GraphEntity>> entitiesBySession;
  final Map<String, List<GraphRelation>> relationsBySession;
}

/// Cloud-side FTS fallback (architecture §5.4). Calls the `search_sessions`
/// Postgres function (see the Supabase migration), which returns matching
/// sessions with a `ts_headline` excerpt; the server's `<mark>` tags are
/// translated to the app's `\x01`/`\x02` highlight markers so the UI renders
/// them identically to local FTS snippets.
class SupabaseSearchDataSource implements SearchRepository {
  SupabaseSearchDataSource(this._client);

  final SupabaseClient _client;

  @override
  Future<List<SearchResult>> search(String query) async {
    final data = await _client.rpc('search_sessions', params: {
      'p_query': query,
      'p_limit': 20,
    });
    if (data is! List) return const [];
    return [
      for (final row in data)
        SearchResult(
          sessionId: row['session_id'] as String,
          title: row['title'] as String?,
          summary: row['summary'] as String?,
          status: SessionStatus.fromWire(row['status'] as String?) ??
              SessionStatus.ready,
          rank: 0,
          snippet: (row['snippet'] as String?)
              ?.replaceAll('<mark>', '\u0001')
              .replaceAll('</mark>', '\u0002'),
        ),
    ];
  }
}
