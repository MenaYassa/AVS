import 'dart:async';

import 'package:record/record.dart';

import '../../domain/repositories.dart';

/// Recording lifecycle events.
enum RecordingPhase { idle, recording, paused }

/// Swappable voice capture (architecture §4.12 — voice input adapter #1).
/// Tests substitute a fake; production uses [RecordVoiceRecorder].
abstract interface class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start({required String outputPath});
  Future<void> pause();
  Future<void> resume();
  Future<String> stop();
  Future<void> cancel();
  RecordingPhase get phase;

  /// Normalized 0..1 amplitude samples emitted while recording (live
  /// waveform, spec §5).
  Stream<double> get amplitude;
}

/// Production recorder backed by the `record` package (architecture §3.1).
class RecordVoiceRecorder implements VoiceRecorder {
  final AudioRecorder _recorder = AudioRecorder();
  final StreamController<double> _amplitudeController =
      StreamController<double>.broadcast();
  RecordingPhase _phase = RecordingPhase.idle;
  StreamSubscription<Amplitude>? _amplitudeSub;

  @override
  RecordingPhase get phase => _phase;

  @override
  Stream<double> get amplitude => _amplitudeController.stream;

  @override
  Future<bool> hasPermission() async {
    if (!await _recorder.hasPermission()) {
      throw const RecordingFailure('Microphone permission denied.');
    }
    return true;
  }

  @override
  Future<void> start({required String outputPath}) async {
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
        autoGain: true,
        echoCancel: true,
      ),
      path: outputPath,
    );
    _phase = RecordingPhase.recording;
    await _amplitudeSub?.cancel();
    _amplitudeSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((a) {
      // dBFS (−60..0) → normalized 0..1.
      final normalized = ((a.current + 60) / 60).clamp(0.0, 1.0);
      _amplitudeController.add(normalized);
    });
  }

  @override
  Future<void> pause() async {
    await _recorder.pause();
    _phase = RecordingPhase.paused;
  }

  @override
  Future<void> resume() async {
    await _recorder.resume();
    _phase = RecordingPhase.recording;
  }

  @override
  Future<String> stop() async {
    final path = await _recorder.stop();
    await _amplitudeSub?.cancel();
    _phase = RecordingPhase.idle;
    if (path == null) {
      throw const RecordingFailure('Recording stopped but produced no file.');
    }
    return path;
  }

  @override
  Future<void> cancel() async {
    await _recorder.cancel();
    await _amplitudeSub?.cancel();
    _phase = RecordingPhase.idle;
  }

  Future<void> dispose() async {
    await _amplitudeSub?.cancel();
    await _amplitudeController.close();
    _recorder.dispose();
  }
}
