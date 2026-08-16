package com.example.data.audio

import android.content.Context
import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.io.File

data class AudioPlaybackState(
    val isPlaying: Boolean = false,
    val currentPositionMs: Int = 0,
    val durationMs: Int = 0,
    val progress: Float = 0f,
    val playbackSpeed: Float = 1.0f,
    val isReady: Boolean = false,
    val errorMessage: String? = null
)

class AudioPlayer(private val context: Context) {
    private var mediaPlayer: MediaPlayer? = null
    private var updateJob: Job? = null
    private var currentFilePath: String? = null

    private val _playbackState = MutableStateFlow(AudioPlaybackState())
    val playbackState: StateFlow<AudioPlaybackState> = _playbackState.asStateFlow()

    fun loadAudio(filePath: String?) {
        if (filePath.isNullOrBlank()) {
            _playbackState.value = AudioPlaybackState(errorMessage = "No audio file available")
            return
        }

        val file = File(filePath)
        if (!file.exists() || file.length() == 0L) {
            _playbackState.value = AudioPlaybackState(errorMessage = "Audio file does not exist on disk")
            return
        }

        try {
            stop()
            currentFilePath = filePath
            mediaPlayer = MediaPlayer().apply {
                setDataSource(filePath)
                prepare()
                val dur = duration.coerceAtLeast(1)
                _playbackState.value = AudioPlaybackState(
                    durationMs = dur,
                    isReady = true
                )
                setOnCompletionListener {
                    _playbackState.value = _playbackState.value.copy(
                        isPlaying = false,
                        currentPositionMs = 0,
                        progress = 0f
                    )
                    stopProgressUpdates()
                }
                setOnErrorListener { _, what, extra ->
                    Log.e("AudioPlayer", "MediaPlayer error: what=$what, extra=$extra")
                    _playbackState.value = _playbackState.value.copy(
                        isPlaying = false,
                        errorMessage = "Error playing audio file ($what)"
                    )
                    stopProgressUpdates()
                    true
                }
            }
        } catch (e: Exception) {
            Log.e("AudioPlayer", "Failed to load audio: ${e.message}", e)
            _playbackState.value = AudioPlaybackState(errorMessage = "Cannot read audio file: ${e.localizedMessage}")
        }
    }

    fun play(scope: CoroutineScope) {
        val player = mediaPlayer ?: run {
            currentFilePath?.let { loadAudio(it) }
            mediaPlayer
        } ?: return

        try {
            if (!_playbackState.value.isPlaying) {
                applyPlaybackSpeed(_playbackState.value.playbackSpeed)
                player.start()
                _playbackState.value = _playbackState.value.copy(isPlaying = true)
                startProgressUpdates(scope)
            }
        } catch (e: Exception) {
            Log.e("AudioPlayer", "Play error: ${e.message}", e)
        }
    }

    fun pause() {
        try {
            mediaPlayer?.let {
                if (it.isPlaying) {
                    it.pause()
                }
            }
            _playbackState.value = _playbackState.value.copy(isPlaying = false)
            stopProgressUpdates()
        } catch (e: Exception) {
            Log.e("AudioPlayer", "Pause error: ${e.message}", e)
        }
    }

    fun togglePlayPause(scope: CoroutineScope) {
        if (_playbackState.value.isPlaying) {
            pause()
        } else {
            play(scope)
        }
    }

    fun seekTo(progress: Float) {
        val player = mediaPlayer ?: return
        try {
            val totalDuration = player.duration
            val targetMs = (totalDuration * progress.coerceIn(0f, 1f)).toInt()
            player.seekTo(targetMs)
            _playbackState.value = _playbackState.value.copy(
                currentPositionMs = targetMs,
                progress = progress.coerceIn(0f, 1f)
            )
        } catch (e: Exception) {
            Log.e("AudioPlayer", "Seek error: ${e.message}", e)
        }
    }

    fun setPlaybackSpeed(speed: Float) {
        _playbackState.value = _playbackState.value.copy(playbackSpeed = speed)
        applyPlaybackSpeed(speed)
    }

    private fun applyPlaybackSpeed(speed: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                mediaPlayer?.let { player ->
                    if (player.isPlaying || _playbackState.value.isReady) {
                        val params = player.playbackParams ?: PlaybackParams()
                        params.speed = speed
                        player.playbackParams = params
                    }
                }
            } catch (e: Exception) {
                Log.w("AudioPlayer", "PlaybackParams error: ${e.message}")
            }
        }
    }

    private fun startProgressUpdates(scope: CoroutineScope) {
        stopProgressUpdates()
        updateJob = scope.launch(Dispatchers.Main) {
            while (isActive && _playbackState.value.isPlaying) {
                mediaPlayer?.let { player ->
                    try {
                        if (player.isPlaying) {
                            val cur = player.currentPosition
                            val total = player.duration.coerceAtLeast(1)
                            val progress = (cur.toFloat() / total.toFloat()).coerceIn(0f, 1f)
                            _playbackState.value = _playbackState.value.copy(
                                currentPositionMs = cur,
                                durationMs = total,
                                progress = progress
                            )
                        }
                    } catch (e: Exception) {
                        // ignore during transitions
                    }
                }
                delay(100)
            }
        }
    }

    private fun stopProgressUpdates() {
        updateJob?.cancel()
        updateJob = null
    }

    fun stop() {
        try {
            stopProgressUpdates()
            mediaPlayer?.apply {
                if (isPlaying) stop()
                release()
            }
            mediaPlayer = null
            _playbackState.value = _playbackState.value.copy(isPlaying = false, currentPositionMs = 0, progress = 0f)
        } catch (e: Exception) {
            Log.e("AudioPlayer", "Stop error: ${e.message}", e)
        }
    }

    fun release() {
        stop()
    }
}
