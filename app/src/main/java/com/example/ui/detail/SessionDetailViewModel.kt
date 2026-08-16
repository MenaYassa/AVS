package com.example.ui.detail

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.data.audio.AudioPlayer
import com.example.data.model.*
import com.example.data.repository.KnowledgeRepository
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch

enum class DetailTab(val label: String) {
    TOPICS("Topics & Tasks"),
    GRAPH("Knowledge Graph"),
    TRANSCRIPT("Summary & Text"),
    CHAT("AI Copilot"),
    COMMANDS("Drafts & AI"),
    HISTORY("Versions")
}

data class DetailUiState(
    val session: Session? = null,
    val selectedTab: DetailTab = DetailTab.TOPICS,
    val isPlayingAudio: Boolean = false,
    val audioProgress: Float = 0f,
    val playbackSpeed: Float = 1.0f,
    val chatMessages: List<ChatMessage> = emptyList(),
    val drafts: List<CommandDraft> = emptyList(),
    val versions: List<SessionVersion> = emptyList(),
    val selectedEntity: GraphEntity? = null,
    val isRunningCommand: Boolean = false,
    val isSendingChat: Boolean = false
)

class SessionDetailViewModel(
    application: Application,
    private val sessionId: String
) : AndroidViewModel(application) {

    private val repository = KnowledgeRepository.getInstance(application)
    private val audioPlayer = AudioPlayer(application)

    private val _selectedTab = MutableStateFlow(DetailTab.TOPICS)
    private val _selectedEntity = MutableStateFlow<GraphEntity?>(null)
    private val _isRunningCommand = MutableStateFlow(false)
    private val _isSendingChat = MutableStateFlow(false)

    private val sessionFlow = repository.getSessionFlow(sessionId).onEach { session ->
        if (session?.audioPath != null) {
            audioPlayer.loadAudio(session.audioPath)
        }
    }
    private val chatFlow = repository.getChatMessages(sessionId)
    private val draftsFlow = repository.getDraftsForSession(sessionId)
    private val versionsFlow = repository.getVersionsForSession(sessionId)

    private val auxiliaryData = combine(chatFlow, draftsFlow, versionsFlow) { chat, drafts, versions ->
        Triple(chat, drafts, versions)
    }

    val uiState: StateFlow<DetailUiState> = combine(
        sessionFlow,
        _selectedTab,
        audioPlayer.playbackState,
        auxiliaryData,
        _selectedEntity
    ) { session, tab, playback, aux, entity ->
        DetailUiState(
            session = session,
            selectedTab = tab,
            isPlayingAudio = playback.isPlaying,
            audioProgress = playback.progress,
            playbackSpeed = playback.playbackSpeed,
            chatMessages = aux.first,
            drafts = aux.second,
            versions = aux.third,
            selectedEntity = entity,
            isRunningCommand = _isRunningCommand.value,
            isSendingChat = _isSendingChat.value
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = DetailUiState()
    )

    fun selectTab(tab: DetailTab) {
        _selectedTab.value = tab
    }

    fun selectEntity(entity: GraphEntity?) {
        _selectedEntity.value = entity
    }

    fun togglePlayPause() {
        val currentAudioPath = uiState.value.session?.audioPath
        if (currentAudioPath != null) {
            audioPlayer.togglePlayPause(viewModelScope)
        }
    }

    fun seekTo(progress: Float) {
        audioPlayer.seekTo(progress)
    }

    fun setPlaybackSpeed(speed: Float) {
        audioPlayer.setPlaybackSpeed(speed)
    }

    fun toggleItemCompletion(topicId: String, itemId: String) {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            repository.toggleItemCompletion(currentSession, topicId, itemId)
        }
    }

    fun toggleFavorite() {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            repository.toggleFavorite(currentSession.id, currentSession.favorite)
        }
    }

    fun togglePin() {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            repository.togglePinned(currentSession.id, currentSession.pinned)
        }
    }

    fun runCommand(commandName: String, onComplete: (String) -> Unit) {
        val currentSession = uiState.value.session ?: return
        _isRunningCommand.value = true
        viewModelScope.launch {
            val draft = repository.runCommand(commandName, currentSession)
            _isRunningCommand.value = false
            onComplete(draft.id)
        }
    }

    fun sendChatMessage(query: String, isThinkingMode: Boolean = false, isFastMode: Boolean = false) {
        val currentSession = uiState.value.session ?: return
        if (query.isBlank()) return
        _isSendingChat.value = true
        viewModelScope.launch {
            repository.sendChatMessage(currentSession, query, isThinkingMode, isFastMode)
            _isSendingChat.value = false
        }
    }

    fun restoreVersion(version: SessionVersion) {
        viewModelScope.launch {
            repository.restoreVersion(version)
        }
    }

    fun updateSessionTitle(newTitle: String) {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            val updated = currentSession.copy(title = newTitle, updatedAt = System.currentTimeMillis())
            repository.saveSession(updated)
            repository.createVersionSnapshot(updated, "Renamed session to '$newTitle'")
        }
    }

    fun addNewItemToTopic(topicId: String, title: String, type: ItemType, priority: Priority) {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            val newItem = Item(
                id = "item_${java.util.UUID.randomUUID().toString().take(8)}",
                type = type,
                title = title,
                position = 99,
                priority = priority,
                confidence = 1.0,
                completed = false
            )
            val newTopics = currentSession.topics.map { topic ->
                if (topic.id == topicId) topic.copy(items = topic.items + newItem) else topic
            }
            val updated = currentSession.copy(topics = newTopics, updatedAt = System.currentTimeMillis())
            repository.saveSession(updated)
            repository.createVersionSnapshot(updated, "Added manual item '$title'")
        }
    }

    fun updateItem(
        topicId: String,
        itemId: String,
        newTitle: String,
        newDescription: String,
        newType: ItemType,
        newPriority: Priority,
        isCompleted: Boolean
    ) {
        val currentSession = uiState.value.session ?: return
        if (newTitle.isBlank()) return
        viewModelScope.launch {
            repository.updateItem(
                session = currentSession,
                topicId = topicId,
                itemId = itemId,
                newTitle = newTitle.trim(),
                newDescription = newDescription.trim(),
                newType = newType,
                newPriority = newPriority,
                isCompleted = isCompleted
            )
        }
    }

    fun deleteItem(topicId: String, itemId: String) {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            repository.deleteItem(currentSession, topicId, itemId)
        }
    }

    fun seekToSecond(seconds: Double) {
        val currentSession = uiState.value.session ?: return
        val totalSec = currentSession.durationSec ?: return
        if (totalSec > 0) {
            val progress = (seconds / totalSec).toFloat().coerceIn(0f, 1f)
            audioPlayer.seekTo(progress)
        }
    }

    fun applyPersona(persona: PromptPersona) {
        val currentSession = uiState.value.session ?: return
        viewModelScope.launch {
            val text = currentSession.cleanedTranscript ?: currentSession.originalTranscript ?: ""
            if (text.isNotBlank()) {
                val reAnalyzed = com.example.data.engine.AiKnowledgeEngine.analyze(text, persona)
                    .copy(id = currentSession.id, title = currentSession.title, audioPath = currentSession.audioPath, durationSec = currentSession.durationSec, favorite = currentSession.favorite, pinned = currentSession.pinned)
                repository.saveSession(reAnalyzed)
                repository.createVersionSnapshot(reAnalyzed, "Applied Persona: ${persona.label}")
            }
        }
    }

    fun getExportContent(format: ExportFormat): String {
        val currentSession = uiState.value.session ?: return ""
        return com.example.data.engine.AiKnowledgeEngine.formatSessionForExport(currentSession, format)
    }

    override fun onCleared() {
        super.onCleared()
        audioPlayer.release()
    }
}
