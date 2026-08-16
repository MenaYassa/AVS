import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/session.dart';
import '../../domain/repositories.dart';

/// Organization actions: favorites, archive, trash (+ restore), pin (§4.2).
///
/// All mutations go through `SessionRepository.updateSession` so they persist
/// locally and sync via the write-through outbox as a full-document upsert
/// (org flags are part of the canonical JSON payload). Trash is a soft delete
/// (`deleted = true`) so sessions can be restored; only purge hard-deletes.
final organizationControllerProvider =
    Provider<OrganizationController>((ref) {
  return OrganizationController(ref.read(databaseProvider));
});

class OrganizationController {
  OrganizationController(this._sessions);

  final SessionRepository _sessions;

  Future<void> toggleFavorite(Session session) =>
      _mutate(session, session.copyWith(favorite: !session.favorite));

  Future<void> toggleArchive(Session session) => _mutate(
      session, session.copyWith(archived: !session.archived));

  Future<void> togglePin(Session session) =>
      _mutate(session, session.copyWith(pinned: !session.pinned));

  /// Soft delete: moves the session to trash so it can be restored.
  Future<void> trash(Session session) => _mutate(session,
      session.copyWith(deleted: true, archived: false));

  Future<void> restore(Session session) =>
      _mutate(session, session.copyWith(deleted: false));

  /// Hard delete from trash (also removes topics/items + cloud tombstone).
  Future<void> purge(Session session) => _sessions.deleteSession(session.id);

  Future<void> _mutate(Session session, Session updated) async {
    await _sessions.updateSession(
      updated.copyWith(updatedAt: DateTime.now().toUtc()),
    );
  }
}
