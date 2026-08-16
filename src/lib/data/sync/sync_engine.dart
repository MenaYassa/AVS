import 'dart:convert';

import '../../domain/editing/conflict_resolver.dart';
import '../../domain/entities/session.dart';
import '../../domain/entities/tag.dart';
import '../../domain/repositories.dart';
import '../local/database.dart';
import '../local/local_data_source.dart';
import '../mappers/mappers.dart';

/// Outcome of one sync pass (architecture §4.13).
class SyncRunResult {
  const SyncRunResult({
    this.pushed = 0,
    this.pulled = 0,
    this.deleted = 0,
    this.failed = 0,
    this.conflicts = 0,
    this.completedAt,
  });

  /// Sessions pushed from the outbox.
  final int pushed;

  /// Sessions applied from the cloud pull.
  final int pulled;

  /// Tombstoned sessions removed locally.
  final int deleted;

  /// Outbox records that could not be pushed this pass.
  final int failed;

  /// True conflicts flagged during diff resolution (architecture §4.13).
  final int conflicts;

  /// When the pass finished (null for the idle/empty result).
  final DateTime? completedAt;

  SyncRunResult copyWith({
    int? pushed,
    int? pulled,
    int? deleted,
    int? failed,
    int? conflicts,
    DateTime? completedAt,
  }) {
    return SyncRunResult(
      pushed: pushed ?? this.pushed,
      pulled: pulled ?? this.pulled,
      deleted: deleted ?? this.deleted,
      failed: failed ?? this.failed,
      conflicts: conflicts ?? this.conflicts,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  static const empty = SyncRunResult();
}

/// Write-through outbox drain + incremental pull (architecture §4.13).
///
/// - Push: oldest-first pending outbox records; transient failures stay
///   pending (bounded retries), hard failures are marked `failed`.
///   `upsert`/`delete` records are the plain full-document path; `oplog_diff`
///   records (op-log edits) are resolved as **diffs, not documents**: the
///   pending base + operations are replayed onto the current cloud state by
///   the [ConflictResolver] (field-level LWW + flagged true conflicts), the
///   merged result is pushed, flagged conflicts are persisted for review, and
///   the log watermark advances.
/// - Pull: `updated_at > last_sync` per user, tombstones applied as local
///   deletions, cursor advanced to the newest seen timestamp.
///
/// The pull path writes outbox-free via the DAOs so a pull never re-enqueues a
/// sync record (no sync loop).
class SyncEngine {
  SyncEngine({
    required AppDatabase db,
    required this.remote,
  })  : db = db,
        _logs = EditLogLocalDataSource(db),
        _conflicts = SyncConflictLocalDataSource(db);

  final AppDatabase db;
  final SyncRepository remote;
  final EditLogRepository _logs;
  final ConflictRepository _conflicts;

  static const maxAttempts = 5;

  Future<SyncRunResult> sync({required String userId}) async {
    final (pushed, failed, conflicts) = await _pushPending();
    var pulled = 0;
    var deleted = 0;
    try {
      (pulled, deleted) = await _pullChanged(userId);
    } catch (_) {
      // Offline/cloud failure: leave the cursor and outbox untouched; a later
      // pass retries the pull.
    }
    return SyncRunResult(
      pushed: pushed,
      pulled: pulled,
      deleted: deleted,
      failed: failed,
      conflicts: conflicts,
    );
  }

  Future<(int, int, int)> _pushPending() async {
    var pushed = 0;
    var failed = 0;
    var conflicts = 0;
    final pending = await db.syncDao.peekPending();
    for (final record in pending) {
      try {
        switch ((record.entityType, record.op)) {
          case ('session', 'upsert'):
            final payload =
                jsonDecode(record.payloadJson!) as Map<String, dynamic>;
            final session = Session.fromCanonicalJson(
              payload,
              userId: record.userId,
            ).copyWith(
              updatedAt:
                  DateTime.tryParse(payload['updated_at'] as String? ?? ''),
            );
            await remote.pushSession(session);
          case ('session', 'delete'):
            await remote.deleteSession(
              userId: record.userId,
              sessionId: record.entityId,
            );
          case ('session', 'oplog_diff'):
            conflicts += await _pushDiff(record.userId, record.entityId);
          case ('tag', 'upsert'):
            final payload =
                jsonDecode(record.payloadJson!) as Map<String, dynamic>;
            await remote.pushTag(Tag(
              id: record.entityId,
              userId: payload['user_id'] as String? ?? record.userId,
              name: payload['name'] as String,
              color: payload['color'] as String?,
            ));
          case ('tag', 'delete'):
            await remote.deleteTag(
              userId: record.userId,
              tagId: record.entityId,
            );
          case ('session_tag', 'upsert'):
            final payload =
                jsonDecode(record.payloadJson!) as Map<String, dynamic>;
            await remote.pushSessionTag(
              sessionId: payload['session_id'] as String,
              tagId: payload['tag_id'] as String,
            );
          case ('session_tag', 'delete'):
            // entityId is encoded as '$sessionId:$tagId' (SessionTag ids use
            // a colon separator, so splitting on the last colon is safe).
            final separator = record.entityId.lastIndexOf(':');
            await remote.deleteSessionTag(
              sessionId: record.entityId.substring(0, separator),
              tagId: record.entityId.substring(separator + 1),
            );
        }
        await db.syncDao.markProcessed(record.id);
        pushed++;
      } catch (_) {
        final attempts = record.attempts + 1;
        if (attempts >= maxAttempts) {
          await db.syncDao.markFailed(record.id, attempts);
        } else {
          await db.syncDao.retry(record.id, attempts);
        }
        failed++;
      }
    }
    return (pushed, failed, conflicts);
  }

  /// Resolves one session's pending op-log diff against the cloud and pushes
  /// the merged result. Returns the number of true conflicts flagged.
  Future<int> _pushDiff(String userId, String sessionId) async {
    final diff = await _logs.getPendingDiff(sessionId);
    if (diff == null) return 0; // nothing unsynced (e.g. undone before sync)

    final remoteSession = await remote.pullSession(
      userId: userId,
      sessionId: sessionId,
    );
    // Not on the cloud yet (or a tombstone): replay against the diff's own
    // base so a clean local edit stays clean.
    final remoteBase = remoteSession ?? diff.base;
    final resolution =
        const ConflictResolver().resolve(remote: remoteBase, diff: diff);

    final merged = resolution.merged.copyWith(
      updatedAt: DateTime.now().toUtc(),
    );
    await remote.pushSession(merged);
    if (resolution.conflicts.isNotEmpty) {
      await _conflicts.addAll(sessionId, resolution.conflicts);
    }
    await _logs.markSynced(sessionId, base: merged);
    return resolution.conflicts.length;
  }

  Future<(int, int)> _pullChanged(String userId) async {
    final since = await db.syncDao.getLastSync(userId) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final sessions = await remote.pullChangedSessions(
      userId: userId,
      since: since,
    );

    var newest = since;
    var pulled = 0;
    var deleted = 0;
    if (sessions.isNotEmpty) {
      await db.transaction(() async {
        for (final session in sessions) {
          final updatedAt = session.updatedAt ?? since;
          if (updatedAt.isAfter(newest)) newest = updatedAt;

          if (session.deleted) {
            await db.sessionsDao.deleteSession(session.id);
            // Remove the session's subgraph and prune orphans + dangling edges.
            await db.graphDao.replaceSubgraph(session.id, const [], const {}, const []);
            deleted++;
          } else {
            await db.sessionsDao.upsertSession(sessionToRow(session));
            if (session.topics.isNotEmpty) {
              await db.sessionsDao.replaceTopics(
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
            await db.graphDao.replaceSubgraph(
              session.id,
              [for (final e in session.entities) entityToRow(e)],
              {for (final e in session.entities) e.id: e.confidence},
              [
                for (final r in session.relationships)
                  relationToRow(r, sessionId: session.id),
              ],
            );
            pulled++;
          }
        }
        await db.syncDao.saveCursor(userId, newest);
      });
    }

    // Tags + joins carry no per-row cursor and have small cardinality, so they
    // are refreshed wholesale every pass (even when no sessions changed).
    // Best-effort: a failure here must not fail the session pull above.
    try {
      final tags = await remote.pullTags(userId);
      for (final tag in tags) {
        await db.tagsDao.upsert(tagToRow(tag));
      }
      final joins = await remote.pullSessionTags(userId);
      final localIds = await db.sessionsDao.allSessionIds();
      final bySession = <String, List<String>>{};
      for (final j in joins) {
        if (localIds.contains(j.sessionId)) {
          bySession.putIfAbsent(j.sessionId, () => []).add(j.tagId);
        }
      }
      for (final entry in bySession.entries) {
        await db.tagsDao.setSessionTags(entry.key, entry.value);
      }
    } catch (_) {
      // Ignore: tag refresh is best-effort within a pass.
    }
    return (pulled, deleted);
  }
}
