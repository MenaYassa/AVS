import 'dart:io';

import '../entities/session.dart';
import '../repositories.dart';

/// Removes the raw recording for a session ("delete audio after processing",
/// spec §18, architecture §12). Only the local file is deleted — transcripts,
/// topics, and versions are untouched — and the cleared `audioPath` syncs as a
/// normal session upsert.
class DeleteSessionAudio {
  const DeleteSessionAudio(this._sessions);

  final SessionRepository _sessions;

  Future<void> call(Session session) async {
    final path = session.audioPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // The file may already be gone; still clear the reference.
    }
    await _sessions.updateSession(session.copyWith(
      clearAudioPath: true,
      updatedAt: DateTime.now().toUtc(),
    ));
  }
}
