package com.example.ui.recording

import android.app.Application
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.data.audio.AudioRecorder
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.firebase.FirebaseAuthManager
import com.example.data.firebase.FirestorePersistenceManager
import com.example.data.gemini.GeminiClient
import com.example.data.model.Session
import com.example.data.repository.KnowledgeRepository
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.File

enum class RecordingState {
    IDLE,
    RECORDING,
    PAUSED,
    PROCESSING,
    COMPLETED,
    ERROR
}

data class RecordingUiState(
    val state: RecordingState = RecordingState.IDLE,
    val elapsedSeconds: Int = 0,
    val liveTranscript: String = "",
    val processingStage: String = "",
    val processingProgress: Float = 0f,
    val createdSessionId: String? = null,
    val amplitude: Int = 0,
    val errorMessage: String? = null
)

class RecordingViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)
    private val authManager = FirebaseAuthManager.getInstance(application)
    private val firestoreManager = FirestorePersistenceManager(application, repository)
    private val audioRecorder = AudioRecorder(application)

    private val _uiState = MutableStateFlow(RecordingUiState())
    val uiState: StateFlow<RecordingUiState> = _uiState.asStateFlow()

    private var timerJob: Job? = null
    private var amplitudeJob: Job? = null
    private var recordedAudioFile: File? = null

    fun startRecording() {
        val file = audioRecorder.startRecording()
        if (file == null) {
            _uiState.value = _uiState.value.copy(
                state = RecordingState.ERROR,
                errorMessage = "Microphone initialization failed. Please check microphone permission."
            )
            return
        }

        recordedAudioFile = file
        _uiState.value = _uiState.value.copy(
            state = RecordingState.RECORDING,
            elapsedSeconds = 0,
            errorMessage = null,
            liveTranscript = "Listening to microphone... Speak clearly to capture your thoughts."
        )

        // Timer job
        timerJob?.cancel()
        timerJob = viewModelScope.launch {
            while (true) {
                delay(1000)
                if (_uiState.value.state == RecordingState.RECORDING) {
                    _uiState.value = _uiState.value.copy(
                        elapsedSeconds = _uiState.value.elapsedSeconds + 1
                    )
                }
            }
        }

        // Amplitude polling job for live waveform
        amplitudeJob?.cancel()
        amplitudeJob = viewModelScope.launch {
            while (true) {
                delay(100)
                if (_uiState.value.state == RecordingState.RECORDING) {
                    val amp = audioRecorder.getMaxAmplitude()
                    _uiState.value = _uiState.value.copy(amplitude = amp)
                }
            }
        }
    }

    fun pauseRecording() {
        _uiState.value = _uiState.value.copy(state = RecordingState.PAUSED)
    }

    fun resumeRecording() {
        _uiState.value = _uiState.value.copy(state = RecordingState.RECORDING)
    }

    fun stopAndProcess() {
        amplitudeJob?.cancel()
        timerJob?.cancel()

        val audioBytes = audioRecorder.stopRecording()
        val duration = _uiState.value.elapsedSeconds.toDouble().coerceAtLeast(1.0)

        _uiState.value = _uiState.value.copy(
            state = RecordingState.PROCESSING,
            processingProgress = 0.15f,
            processingStage = "Transcribing spoken audio via AI Knowledge Pipeline..."
        )

        viewModelScope.launch {
            var finalTranscript = ""

            // 1. Audio Transcription using active STT provider
            if (audioBytes != null && audioBytes.isNotEmpty()) {
                val transcribeResult = GeminiClient.transcribeAudioWithConfig(getApplication(), audioBytes, "audio/mp4")
                transcribeResult.onSuccess { transcribedText ->
                    if (transcribedText.isNotBlank()) {
                        finalTranscript = transcribedText
                    }
                }.onFailure { error ->
                    Log.w("RecordingViewModel", "Transcription note: ${error.message}")
                    finalTranscript = ""
                }
            }

            _uiState.value = _uiState.value.copy(
                processingStage = "Stage 1/3: Analyzing topics and key insights...",
                processingProgress = 0.45f
            )
            delay(250)

            _uiState.value = _uiState.value.copy(
                processingStage = "Stage 2/3: Extracting action items and decisions...",
                processingProgress = 0.70f
            )
            delay(250)

            _uiState.value = _uiState.value.copy(
                processingStage = "Stage 3/3: Mapping knowledge graph relationships...",
                processingProgress = 0.90f
            )
            delay(200)

            // Analyze & create session
            val session = AiKnowledgeEngine.analyze(
                rawText = finalTranscript,
                audioDurationSec = duration,
                audioPath = recordedAudioFile?.absolutePath
            )

            // Local Room persistence + version snapshot
            repository.saveSession(session)
            repository.createVersionSnapshot(session, "Initial Audio Capture")

            // Cloud Firestore persistence if signed in
            val user = authManager.userState.value
            if (user.isSignedIn && user.userId != null) {
                firestoreManager.pushSession(user.userId, session)
            }

            _uiState.value = _uiState.value.copy(
                state = RecordingState.COMPLETED,
                processingStage = "Session saved successfully!",
                processingProgress = 1.0f,
                createdSessionId = session.id
            )
        }
    }

    fun cancelRecording() {
        amplitudeJob?.cancel()
        timerJob?.cancel()
        audioRecorder.cancel()
        recordedAudioFile?.delete()
        recordedAudioFile = null
        _uiState.value = RecordingUiState()
    }

    override fun onCleared() {
        super.onCleared()
        amplitudeJob?.cancel()
        timerJob?.cancel()
        audioRecorder.cancel()
    }
}
