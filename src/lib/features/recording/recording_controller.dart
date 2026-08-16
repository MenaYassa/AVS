import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/audio/voice_recorder.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/entities/enums.dart';
import '../../domain/repositories.dart';
import '../../domain/usecases/manage_sessions.dart';
import '../analysis/analysis_controller.dart';
import '../auth/auth_controller.dart';

/// Capture backend (architecture §4.12). Overridable in tests with a fake.
final voiceRecorderProvider = Provider<VoiceRecorder>(
  (ref) => RecordVoiceRecorder(),
);

/// Where new recordings are written (path_provider in production, a temp dir
/// in tests).
final recordingOutputDirectoryProvider = Provider<Future<Directory>>(
  (ref) => getApplicationDocumentsDirectory(),
);

/// Recording session state.
class RecordingState {
  const RecordingState({
    this.phase = RecordingPhase.idle,
    this.duration = Duration.zero,
    this.error,
    this.activeSessionId,
    this.audioPath,
    this.waveform = const [],
  });

  final RecordingPhase phase;
  final Duration duration;
  final String? error;
  final String? activeSessionId;
  final String? audioPath;

  /// Rolling buffer of normalized 0..1 amplitude samples (live waveform).
  final List<double> waveform;

  bool get isRecording => phase == RecordingPhase.recording;

  bool get isPaused => phase == RecordingPhase.paused;

  bool get isActive => phase != RecordingPhase.idle;

  RecordingState copyWith({
    RecordingPhase? phase,
    Duration? duration,
    String? error,
    String? activeSessionId,
    String? audioPath,
    List<double>? waveform,
    bool clearError = false,
  }) {
    return RecordingState(
      phase: phase ?? this.phase,
      duration: duration ?? this.duration,
      error: clearError ? null : (error ?? this.error),
      activeSessionId: activeSessionId ?? this.activeSessionId,
      audioPath: audioPath ?? this.audioPath,
      waveform: waveform ?? this.waveform,
    );
  }
}

final recordingControllerProvider = NotifierProvider<RecordingController, RecordingState>(
  RecordingController.new,
);

class RecordingController extends Notifier<RecordingState> {
  VoiceRecorder? _recorder;
  Timer? _ticker;
  StreamSubscription<double>? _amplitudeSub;

  /// Maximum waveform samples kept in state.
  static const int waveformCapacity = 48;

  @override
  RecordingState build() => const RecordingState();

  VoiceRecorder get _resolveRecorder {
    _recorder ??= ref.read(voiceRecorderProvider);
    return _recorder!;
  }

  Future<void> start() async {
    try {
      final userId = ref.read(authControllerProvider).valueOrNull;
      final recorder = _resolveRecorder;
      await recorder.hasPermission();

      final dir = await ref.read(recordingOutputDirectoryProvider);
      final session = await StartSessionDraft(ref.read(databaseProvider))(
        userId: userId,
      );
      final path = '${dir.path}/${session.id}.m4a';

      await recorder.start(outputPath: path);
      _startTicker();
      _startAmplitudeMonitoring(recorder);
      state = state.copyWith(
        phase: RecordingPhase.recording,
        activeSessionId: session.id,
        audioPath: path,
        waveform: const [],
        clearError: true,
      );
    } on AppFailure catch (e) {
      state = state.copyWith(error: e.message);
    } catch (e, st) {
      Log.e('Failed to start recording', e, st);
      state = state.copyWith(error: 'Could not start recording.');
    }
  }

  Future<void> pause() async {
    await _resolveRecorder.pause();
    _ticker?.cancel();
    state = state.copyWith(phase: RecordingPhase.paused);
  }

  Future<void> resume() async {
    await _resolveRecorder.resume();
    _startTicker();
    state = state.copyWith(phase: RecordingPhase.recording);
  }

  Future<void> stop() async {
    try {
      final path = await _resolveRecorder.stop();
      _ticker?.cancel();
      _stopAmplitudeMonitoring();
      final sessionId = state.activeSessionId;
      if (sessionId != null) {
        final repo = ref.read(databaseProvider);
        final session = await repo.getSession(sessionId);
        if (session != null) {
          await repo.updateSession(
            session.copyWith(
              status: SessionStatus.ready,
              audioPath: path,
              durationSec: state.duration.inMilliseconds / 1000.0,
              updatedAt: DateTime.now().toUtc(),
            ),
          );
          // New recording → kick off analysis automatically (§2.4). The
          // analysis controller is fail-safe: any setup error surfaces there
          // as a retryable failure rather than propagating.
          unawaited(
            ref.read(analysisControllerProvider(sessionId).notifier).analyze(),
          );
        }
      }
      state = state.copyWith(
        phase: RecordingPhase.idle,
        audioPath: path,
        duration: Duration.zero,
        waveform: const [],
      );
    } on AppFailure catch (e) {
      state = state.copyWith(error: e.message);
    } catch (e, st) {
      Log.e('Failed to stop recording', e, st);
      state = state.copyWith(error: 'Could not finish the recording.');
    }
  }

  Future<void> cancel() async {
    _ticker?.cancel();
    _stopAmplitudeMonitoring();
    await _resolveRecorder.cancel();
    final sessionId = state.activeSessionId;
    if (sessionId != null) {
      await ref.read(databaseProvider).deleteSession(sessionId);
    }
    state = const RecordingState();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      state = state.copyWith(duration: state.duration + const Duration(seconds: 1));
    });
  }

  void _startAmplitudeMonitoring(VoiceRecorder recorder) {
    _stopAmplitudeMonitoring();
    _amplitudeSub = recorder.amplitude.listen((sample) {
      final buffer = [...state.waveform, sample];
      if (buffer.length > waveformCapacity) {
        buffer.removeRange(0, buffer.length - waveformCapacity);
      }
      state = state.copyWith(waveform: buffer);
    });
  }

  void _stopAmplitudeMonitoring() {
    _amplitudeSub?.cancel();
    _amplitudeSub = null;
  }
}
