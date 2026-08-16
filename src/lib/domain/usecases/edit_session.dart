import '../entities/session.dart';
import '../editing/edit_operations.dart';
import '../editing/operation_log.dart';
import '../repositories.dart';

/// Outcome of an editing action: the new session plus the updated log.
typedef EditSessionResult = ({Session session, OperationLog log});

/// Pure edit orchestration over the repository seam (architecture §3.2, §3.4).
///
/// Every mutation goes through [apply] (the single mutation path): the op is
/// applied to the session, the session is persisted, and the log — including
/// the new op — is persisted so undo/redo and diff sync keep working across
/// restarts.
class EditSession {
  EditSession(this._sessions, this._log);

  final SessionRepository _sessions;
  final EditLogRepository _log;

  Future<EditSessionResult> apply({
    required Session session,
    required OperationLog log,
    required EditOperation op,
  }) async {
    final next = log.applyOp(session, op);
    await _sessions.updateSession(next, emitDiff: true);
    await _log.saveLog(session.id, log, diffBase: session);
    return (session: next, log: log);
  }

  /// Applies a continuous batch as a single log entry.
  Future<EditSessionResult> applyBatch({
    required Session session,
    required OperationLog log,
    required List<EditOperation> ops,
  }) async {
    final next = log.applyBatch(session, ops);
    await _sessions.updateSession(next, emitDiff: true);
    await _log.saveLog(session.id, log, diffBase: session);
    return (session: next, log: log);
  }

  /// Undoes the last batch (inverses applied in reverse order) and persists.
  Future<EditSessionResult> undo({
    required Session session,
    required OperationLog log,
  }) async {
    final batch = log.undo();
    if (batch.isEmpty) return (session: session, log: log);
    var next = session;
    for (final op in batch.reversed) {
      next = op.inverse().apply(next);
    }
    await _sessions.updateSession(next, emitDiff: true);
    await _log.saveLog(session.id, log, diffBase: session);
    return (session: next, log: log);
  }

  /// Re-applies the next batch after an undo and persists.
  Future<EditSessionResult> redo({
    required Session session,
    required OperationLog log,
  }) async {
    final batch = log.redo();
    if (batch.isEmpty) return (session: session, log: log);
    var next = session;
    for (final op in batch) {
      next = op.apply(next);
    }
    await _sessions.updateSession(next, emitDiff: true);
    await _log.saveLog(session.id, log, diffBase: session);
    return (session: next, log: log);
  }
}
