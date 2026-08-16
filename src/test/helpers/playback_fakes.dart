import 'dart:async';

import 'package:ai_knowledge_companion/core/audio/audio_player.dart';

/// Controllable [SessionAudioPlayer] for playback tests. Streams are driven by
/// the test via the `emit*` helpers; `setSource` failure is injected with
/// [failNextSetSource].
class FakeSessionAudioPlayer implements SessionAudioPlayer {
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _duration =
      StreamController<Duration?>.broadcast();
  final StreamController<bool> _playing = StreamController<bool>.broadcast();
  final StreamController<void> _error = StreamController<void>.broadcast();

  @override
  bool playing = false;
  bool disposed = false;

  @override
  Duration? position;

  @override
  Duration? duration;
  double speed = 1.0;
  String? source;
  int setSourceCalls = 0;
  bool failNextSetSource = false;

  void emitPosition(Duration value) => _position.add(value);
  void emitDuration(Duration value) => _duration.add(value);
  void emitPlaying(bool value) => _playing.add(value);
  void emitError() => _error.add(null);

  @override
  Future<void> setSource(String source) async {
    setSourceCalls++;
    this.source = source;
    if (failNextSetSource) {
      failNextSetSource = false;
      _error.add(null);
      throw StateError('load failed');
    }
    duration = const Duration(seconds: 30);
    position = Duration.zero;
    _duration.add(duration);
  }

  @override
  Future<void> play() async {
    playing = true;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    playing = false;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration value) async {
    position = value;
    _position.add(value);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> stop() async {
    playing = false;
    position = null;
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<void> get errorStream => _error.stream;
}
