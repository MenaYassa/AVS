import 'dart:async';

import 'package:ai_knowledge_companion/core/audio/voice_recorder.dart';
import 'package:ai_knowledge_companion/domain/entities/session.dart';
import 'package:ai_knowledge_companion/domain/repositories.dart';

/// Deterministic recorder for widget/controller tests (architecture §4.12 —
/// voice is a swappable input adapter).
class FakeVoiceRecorder implements VoiceRecorder {
  bool permissionGranted = true;
  String? startedPath;
  int startCalls = 0;
  int stopCalls = 0;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int cancelCalls = 0;
  final StreamController<double> _amplitudeController =
      StreamController<double>.broadcast();
  RecordingPhase _phase = RecordingPhase.idle;

  @override
  RecordingPhase get phase => _phase;

  @override
  Stream<double> get amplitude => _amplitudeController.stream;

  /// Emits a normalized amplitude sample (as the real recorder would).
  void pushAmplitude(double value) => _amplitudeController.add(value);

  @override
  Future<bool> hasPermission() async {
    if (!permissionGranted) {
      throw const RecordingFailure('Microphone permission denied.');
    }
    return true;
  }

  @override
  Future<void> start({required String outputPath}) async {
    startCalls++;
    startedPath = outputPath;
    _phase = RecordingPhase.recording;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _phase = RecordingPhase.paused;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    _phase = RecordingPhase.recording;
  }

  @override
  Future<String> stop() async {
    stopCalls++;
    _phase = RecordingPhase.idle;
    return startedPath ?? '/tmp/fake.m4a';
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
    _phase = RecordingPhase.idle;
  }
}

/// In-memory repo that actually mutates on insert/update/delete, so the
/// recording lifecycle transitions are observable from the outside.
class RecordingTestRepo implements SessionRepository {
  final List<Session> sessions = [];

  @override
  Stream<List<Session>> watchSessions({bool includeDeleted = false}) =>
      Stream.value(List.of(sessions));

  @override
  Future<Session?> getSession(String id) async =>
      sessions.where((s) => s.id == id).firstOrNull;

  @override
  Future<Session> insertSession(Session session) async {
    sessions.add(session);
    return session;
  }

  @override
  Future<void> updateSession(Session session, {bool emitDiff = false}) async {
    final i = sessions.indexWhere((s) => s.id == session.id);
    if (i >= 0) sessions[i] = session;
  }

  @override
  Future<void> deleteSession(String id) async {
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Future<void> replaceTopics(String sessionId, List<Topic> topics) async {}

  @override
  Future<List<Topic>> getTopics(String sessionId) async => const [];
}
