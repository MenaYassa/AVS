import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/audio_player.dart';
import '../../core/logging/app_logger.dart';

/// Production playback backend (swappable in tests, mirroring the
/// `voiceRecorderProvider` pattern).
final sessionAudioPlayerProvider = Provider<SessionAudioPlayer>(
  (ref) => JustAudioSessionAudioPlayer(),
);

/// App-scoped playback state (spec §16). One player for the whole app so
/// audio keeps playing across screens and while backgrounded; only the
/// currently loaded session's recording is audible at a time.
class PlaybackState {
  const PlaybackState({
    this.sessionId,
    this.source,
    this.playing = false,
    this.loading = false,
    this.position,
    this.duration,
    this.speed = 1.0,
    this.error,
  });

  final String? sessionId;
  final String? source;
  final bool playing;
  final bool loading;
  final Duration? position;
  final Duration? duration;
  final double speed;
  final String? error;

  /// The given session's recording is the one loaded (and thus playable).
  bool isCurrent(String sessionId, String source) =>
      this.sessionId == sessionId && this.source == source;

  bool get hasSource => source != null;

  PlaybackState copyWith({
    String? sessionId,
    String? source,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
    double? speed,
    String? error,
    bool clearError = false,
  }) {
    return PlaybackState(
      sessionId: sessionId ?? this.sessionId,
      source: source ?? this.source,
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      speed: speed ?? this.speed,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

final playbackControllerProvider =
    NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);

class PlaybackController extends Notifier<PlaybackState> {
  SessionAudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<void>? _errorSub;

  @override
  PlaybackState build() {
    ref.onDispose(_dispose);
    return const PlaybackState();
  }

  SessionAudioPlayer get _resolvePlayer {
    final existing = _player;
    if (existing != null) return existing;
    final player = ref.read(sessionAudioPlayerProvider);
    _player = player;
    return player;
  }

  void _subscribe(SessionAudioPlayer player) {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    _posSub = player.positionStream.listen((p) {
      state = state.copyWith(position: p);
    });
    _durSub = player.durationStream.listen((d) {
      state = state.copyWith(duration: d);
    });
    _playingSub = player.playingStream.listen((playing) {
      state = state.copyWith(playing: playing, clearError: true);
    });
    _errorSub = player.errorStream.listen((_) {
      state = state.copyWith(
        playing: false,
        loading: false,
        error: 'Could not play this recording.',
      );
    });
  }

  /// Loads [source] (local path or remote URL) for [sessionId] and plays it.
  /// Loading the same source again just resumes.
  Future<void> play(String sessionId, String source) async {
    final player = _resolvePlayer;
    if (state.source != source) {
      state = state.copyWith(
        sessionId: sessionId,
        source: source,
        loading: true,
        error: null,
      );
      _subscribe(player);
      try {
        await player.setSource(source);
      } catch (e, st) {
        Log.e('Failed to load audio source', e, st);
        state = state.copyWith(
          loading: false,
          playing: false,
          error: 'Could not play this recording.',
        );
        return;
      }
      state = state.copyWith(loading: false, duration: player.duration);
    }
    await _resume(player);
  }

  /// Play/pause for the session+source currently on screen: resumes if the
  /// same source is loaded, loads+plays otherwise.
  Future<void> toggle(String sessionId, String source) async {
    if (state.isCurrent(sessionId, source)) {
      if (state.playing) {
        await pause();
      } else {
        await _resume(_resolvePlayer);
      }
    } else {
      await play(sessionId, source);
    }
  }

  Future<void> pause() async {
    await _resolvePlayer.pause();
    state = state.copyWith(playing: false);
  }

  Future<void> seek(Duration position) async {
    state = state.copyWith(position: position);
    try {
      await _resolvePlayer.seek(position);
    } catch (e, st) {
      Log.e('Seek failed', e, st);
    }
  }

  Future<void> setSpeed(double speed) async {
    state = state.copyWith(speed: speed);
    try {
      await _resolvePlayer.setSpeed(speed);
    } catch (e, st) {
      Log.e('Set playback speed failed', e, st);
    }
  }

  /// Stops playback and forgets the loaded source (e.g. audio deleted).
  Future<void> stop() async {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    _posSub = _durSub = _playingSub = _errorSub = null;
    final player = _player;
    if (player != null) {
      try {
        await player.stop();
      } catch (e, st) {
        Log.e('Failed to stop playback', e, st);
      }
    }
    state = const PlaybackState();
  }

  /// Stops playback only if [sessionId] is the one currently loaded (used
  /// when a session's recording is deleted).
  Future<void> stopForSession(String sessionId) async {
    if (state.sessionId == sessionId) {
      await stop();
    }
  }

  Future<void> _resume(SessionAudioPlayer player) async {
    try {
      await player.play();
      state = state.copyWith(playing: true, clearError: true);
    } catch (e, st) {
      Log.e('Failed to start playback', e, st);
      state = state.copyWith(
        playing: false,
        error: 'Could not play this recording.',
      );
    }
  }

  Future<void> _dispose() async {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      await player.dispose();
    }
  }
}
