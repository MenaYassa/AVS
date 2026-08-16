import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Swappable playback adapter over a session's recording (spec §16,
/// architecture §3.1 — audio via `just_audio`). Tests substitute a fake;
/// production uses [JustAudioSessionAudioPlayer].
abstract interface class SessionAudioPlayer {
  /// Points the player at a local file path or remote URL.
  Future<void> setSource(String source);

  Future<void> play();

  Future<void> pause();

  Future<void> seek(Duration position);

  Future<void> setSpeed(double speed);

  Future<void> stop();

  Future<void> dispose();

  bool get playing;

  Duration? get position;

  Duration? get duration;

  /// Emits playback position (just_audio cadence, ~200ms).
  Stream<Duration> get positionStream;

  /// Emits the total duration once known (null until the source resolves).
  Stream<Duration?> get durationStream;

  /// Emits play/pause transitions.
  Stream<bool> get playingStream;

  /// Emits when the source fails to load (e.g. the audio file was deleted).
  Stream<void> get errorStream;
}

/// Production player backed by `just_audio`. The underlying platform player
/// is created lazily on the first [setSource] so constructing an adapter is
/// side-effect free (testable without a device), and the player is kept alive
/// for the lifetime of the app so playback continues across screens and while
/// the app is backgrounded (spec §16 "background playback"). Lockscreen media
/// controls would need `audio_service` — tracked as a follow-up.
class JustAudioSessionAudioPlayer implements SessionAudioPlayer {
  final StreamController<Duration> _position =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> _duration =
      StreamController<Duration?>.broadcast();
  final StreamController<bool> _playing =
      StreamController<bool>.broadcast();
  final StreamController<void> _errors = StreamController<void>.broadcast();

  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<ProcessingState>? _processingSub;

  /// Lazily constructs + wires the platform player. `handleInterruptions`
  /// (default) lets the OS duck/pause on phone calls etc.
  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = AudioPlayer();
    _player = player;
    _posSub = player.positionStream.listen(_position.add);
    _durSub = player.durationStream.listen(_duration.add);
    _stateSub = player.playerStateStream
        .listen((s) => _playing.add(s.playing));
    _processingSub = player.processingStateStream
        .listen((s) {
      if (s == ProcessingState.completed) {
        _playing.add(false);
      }
    });
    return player;
  }

  @override
  Future<void> setSource(String source) async {
    final player = _ensurePlayer();
    final audioSource = source.startsWith('http')
        ? AudioSource.uri(Uri.parse(source))
        : AudioSource.file(source);
    try {
      final loadedDuration = await player.setAudioSource(audioSource);
      _duration.add(loadedDuration);
    } catch (_) {
      _errors.add(null);
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    final player = _player;
    if (player == null) return;
    await player.play();
  }

  @override
  Future<void> pause() async {
    final player = _player;
    if (player == null) return;
    await player.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final player = _player;
    if (player == null) return;
    await player.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    final player = _player;
    if (player == null) return;
    await player.setSpeed(speed);
  }

  @override
  Future<void> stop() async {
    final player = _player;
    if (player == null) return;
    await player.stop();
  }

  @override
  Future<void> dispose() async {
    await _posSub?.cancel();
    await _durSub?.cancel();
    await _stateSub?.cancel();
    await _processingSub?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
    }
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _errors.close();
  }

  @override
  bool get playing => _player?.playing ?? false;

  @override
  Duration? get position => _player?.position;

  @override
  Duration? get duration => _player?.duration;

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration?> get durationStream => _duration.stream;

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<void> get errorStream => _errors.stream;
}
