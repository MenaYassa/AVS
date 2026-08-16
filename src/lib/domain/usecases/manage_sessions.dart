import 'package:uuid/uuid.dart';

import '../entities/enums.dart';
import '../entities/session.dart';
import '../repositories.dart';

/// Creates a local session draft when recording starts. Works signed-out
/// (architecture §6: capture is never gated on auth).
class StartSessionDraft {
  const StartSessionDraft(this._sessions);

  final SessionRepository _sessions;
  static const _uuid = Uuid();

  Future<Session> call({required String? userId}) async {
    final now = DateTime.now().toUtc();
    final draft = Session(
      id: _uuid.v4(),
      userId: userId ?? 'local',
      status: SessionStatus.recording,
      createdAt: now,
      updatedAt: now,
    );
    return _sessions.insertSession(draft);
  }
}

/// Creates a local session draft for a manual note (architecture §4.12).
/// A note has no recording or STT stage, so the session starts at `cleaning`
/// (the first pipeline stage) with the note text kept as the original
/// transcript; analysis then runs the rest of the pipeline.
class StartNoteSession {
  const StartNoteSession(this._sessions);

  final SessionRepository _sessions;
  static const _uuid = Uuid();

  Future<Session> call({
    required String? userId,
    required String text,
    String? title,
  }) async {
    final now = DateTime.now().toUtc();
    final trimmedTitle = title?.trim();
    final draft = Session(
      id: _uuid.v4(),
      userId: userId ?? 'local',
      title: (trimmedTitle == null || trimmedTitle.isEmpty)
          ? null
          : trimmedTitle,
      status: SessionStatus.cleaning,
      originalTranscript: text.trim(),
      createdAt: now,
      updatedAt: now,
    );
    return _sessions.insertSession(draft);
  }
}

/// Creates a local session draft for an imported image/PDF document
/// (architecture §4.12). A document is blob-backed like a recording (OCR is
/// the preprocessing step), so the session starts at `uploading` and the
/// picked file path is kept as the input blob path, mirroring the voice flow.
class StartDocumentSession {
  const StartDocumentSession(this._sessions);

  final SessionRepository _sessions;
  static const _uuid = Uuid();

  Future<Session> call({
    required String? userId,
    required String documentPath,
  }) async {
    final now = DateTime.now().toUtc();
    final draft = Session(
      id: _uuid.v4(),
      userId: userId ?? 'local',
      status: SessionStatus.uploading,
      audioPath: documentPath,
      createdAt: now,
      updatedAt: now,
    );
    return _sessions.insertSession(draft);
  }
}

/// Advances a session to a new lifecycle state (architecture §4.5).
class TransitionSessionStatus {
  const TransitionSessionStatus(this._sessions);

  final SessionRepository _sessions;

  Future<Session> call(Session session, SessionStatus status) async {
    final updated = session.copyWith(
      status: status,
      updatedAt: DateTime.now().toUtc(),
    );
    await _sessions.updateSession(updated);
    return updated;
  }
}
