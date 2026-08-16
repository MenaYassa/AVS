package com.example.data.repository

import android.content.Context
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.local.*
import com.example.data.model.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.util.UUID

class KnowledgeRepository(
    private val db: AppDatabase,
    private val context: Context? = null
) {

    val allSessions: Flow<List<Session>> = db.sessionDao().getAllSessionsFlow().map { entities ->
        entities.map { JsonUtils.entityToSession(it) }
    }

    fun getSessionFlow(id: String): Flow<Session?> = db.sessionDao().getSessionByIdFlow(id).map {
        it?.let { JsonUtils.entityToSession(it) }
    }

    suspend fun getAllSessionsList(): List<Session> = withContext(Dispatchers.IO) {
        db.sessionDao().getAllSessionsList().map { JsonUtils.entityToSession(it) }
    }

    suspend fun getSessionById(id: String): Session? = withContext(Dispatchers.IO) {
        db.sessionDao().getSessionById(id)?.let { JsonUtils.entityToSession(it) }
    }

    suspend fun saveSession(session: Session) = withContext(Dispatchers.IO) {
        val updated = session.copyWith(updatedAt = System.currentTimeMillis())
        db.sessionDao().insertOrUpdate(JsonUtils.sessionToEntity(updated))
    }

    suspend fun toggleFavorite(id: String, current: Boolean) = withContext(Dispatchers.IO) {
        db.sessionDao().setFavorite(id, !current, System.currentTimeMillis())
    }

    suspend fun togglePinned(id: String, current: Boolean) = withContext(Dispatchers.IO) {
        db.sessionDao().setPinned(id, !current, System.currentTimeMillis())
    }

    suspend fun toggleArchived(id: String, current: Boolean) = withContext(Dispatchers.IO) {
        db.sessionDao().setArchived(id, !current, System.currentTimeMillis())
    }

    suspend fun setArchived(id: String, archived: Boolean) = withContext(Dispatchers.IO) {
        db.sessionDao().setArchived(id, archived, System.currentTimeMillis())
    }

    suspend fun deleteSession(id: String) = withContext(Dispatchers.IO) {
        db.sessionDao().softDelete(id, System.currentTimeMillis())
    }

    suspend fun restoreSession(session: Session) = withContext(Dispatchers.IO) {
        db.sessionDao().undelete(session.id, System.currentTimeMillis())
    }

    suspend fun renameSession(id: String, newTitle: String) = withContext(Dispatchers.IO) {
        val session = getSessionById(id) ?: return@withContext
        val updated = session.copy(title = newTitle, updatedAt = System.currentTimeMillis())
        saveSession(updated)
        createVersionSnapshot(updated, "Renamed session to '$newTitle'")
    }

    suspend fun duplicateSession(session: Session): Session = withContext(Dispatchers.IO) {
        val newSession = session.copy(
            id = "sess_${UUID.randomUUID().toString().take(8)}",
            title = "${session.title ?: "Session"} (Copy)",
            createdAt = System.currentTimeMillis(),
            updatedAt = System.currentTimeMillis()
        )
        saveSession(newSession)
        createVersionSnapshot(newSession, "Duplicated from ${session.title}")
        newSession
    }

    suspend fun toggleItemCompletion(session: Session, topicId: String, itemId: String) = withContext(Dispatchers.IO) {
        val newTopics = session.topics.map { topic ->
            if (topic.id == topicId) {
                topic.copy(items = topic.items.map { item ->
                    if (item.id == itemId) item.copy(completed = !item.completed) else item
                })
            } else topic
        }
        saveSession(session.copy(topics = newTopics, status = SessionStatus.EDITED))
    }

    suspend fun updateItem(
        session: Session,
        topicId: String,
        itemId: String,
        newTitle: String,
        newDescription: String,
        newType: ItemType,
        newPriority: Priority,
        isCompleted: Boolean
    ) = withContext(Dispatchers.IO) {
        val newTopics = session.topics.map { topic ->
            if (topic.id == topicId) {
                topic.copy(items = topic.items.map { item ->
                    if (item.id == itemId) {
                        item.copy(
                            title = newTitle,
                            description = newDescription,
                            type = newType,
                            priority = newPriority,
                            completed = isCompleted
                        )
                    } else item
                })
            } else topic
        }
        val updated = session.copy(topics = newTopics, status = SessionStatus.EDITED, updatedAt = System.currentTimeMillis())
        saveSession(updated)
        createVersionSnapshot(updated, "Updated item '$newTitle'")
    }

    suspend fun deleteItem(session: Session, topicId: String, itemId: String) = withContext(Dispatchers.IO) {
        val newTopics = session.topics.map { topic ->
            if (topic.id == topicId) {
                topic.copy(items = topic.items.filter { it.id != itemId })
            } else topic
        }
        val updated = session.copy(topics = newTopics, status = SessionStatus.EDITED, updatedAt = System.currentTimeMillis())
        saveSession(updated)
        createVersionSnapshot(updated, "Deleted item")
    }

    suspend fun createVersionSnapshot(session: Session, description: String) = withContext(Dispatchers.IO) {
        val versionsCount = db.sessionVersionDao().getVersionById(session.id)
        val version = SessionVersionEntity(
            id = "ver_${UUID.randomUUID().toString().take(8)}",
            sessionId = session.id,
            versionNumber = (System.currentTimeMillis() % 1000).toInt(),
            title = session.title ?: "Version Snapshot",
            snapshotJson = JsonUtils.json.encodeToString(com.example.data.model.Session.serializer(), session),
            changeDescription = description,
            createdAt = System.currentTimeMillis()
        )
        db.sessionVersionDao().insert(version)
    }

    fun getVersionsForSession(sessionId: String): Flow<List<SessionVersion>> =
        db.sessionVersionDao().getVersionsForSessionFlow(sessionId).map { list ->
            list.map {
                SessionVersion(
                    id = it.id,
                    sessionId = it.sessionId,
                    versionNumber = it.versionNumber,
                    title = it.title,
                    snapshotJson = it.snapshotJson,
                    changeDescription = it.changeDescription,
                    createdAt = it.createdAt
                )
            }
        }

    suspend fun restoreVersion(version: SessionVersion): Session = withContext(Dispatchers.IO) {
        val restoredSession = JsonUtils.json.decodeFromString(com.example.data.model.Session.serializer(), version.snapshotJson)
        val updated = restoredSession.copy(
            updatedAt = System.currentTimeMillis(),
            status = SessionStatus.EDITED
        )
        saveSession(updated)
        createVersionSnapshot(updated, "Restored snapshot from ${java.text.SimpleDateFormat("MMM dd, HH:mm").format(java.util.Date(version.createdAt))}")
        updated
    }

    // Chat
    fun getChatMessages(sessionId: String): Flow<List<ChatMessage>> =
        db.chatMessageDao().getMessagesForSessionFlow(sessionId).map { list ->
            list.map {
                ChatMessage(
                    id = it.id,
                    sessionId = it.sessionId,
                    role = if (it.role == "user") ChatRole.USER else ChatRole.ASSISTANT,
                    content = it.content,
                    citations = JsonUtils.deserializeStringList(it.citationsJson),
                    confidence = it.confidence,
                    promptVersions = JsonUtils.deserializeStringMap(it.promptVersionsJson),
                    createdAt = it.createdAt
                )
            }
        }

    suspend fun sendChatMessage(
        session: Session,
        userText: String,
        isThinkingMode: Boolean = false,
        isFastMode: Boolean = false
    ) = withContext(Dispatchers.IO) {
        val userMsg = ChatMessageEntity(
            id = "chat_${UUID.randomUUID().toString().take(8)}",
            sessionId = session.id,
            role = "user",
            content = userText,
            citationsJson = "[]",
            confidence = null,
            promptVersionsJson = "{}",
            createdAt = System.currentTimeMillis()
        )
        db.chatMessageDao().insert(userMsg)

        // Route via configured AI Provider (Custom OpenAI/Groq/Ollama or Gemini)
        var responseContent: String? = null
        var modelUsed = "local_engine"

        val promptContext = buildString {
            appendLine("Knowledge Session: ${session.title}")
            appendLine("Executive Summary: ${session.summary}")
            appendLine("Topics & Items: ${session.topics.joinToString { t -> "${t.title}: [${t.items.joinToString { it.title }}]" }}")
            appendLine("Knowledge Graph Entities: ${session.entities.joinToString { it.name }}")
            appendLine("Transcript: ${session.cleanedTranscript}")
            appendLine("\nUser Question: $userText")
        }

        if (context != null) {
            val res = com.example.data.gemini.GeminiClient.generateChatWithConfig(
                context = context,
                prompt = promptContext,
                systemPrompt = if (isThinkingMode) {
                    "You are an AI Deep Strategist. Use rigorous high-level thinking to analyze this knowledge session comprehensively and answer the query."
                } else if (isFastMode) {
                    "You are a low-latency AI Knowledge Copilot. Answer rapidly and clearly."
                } else {
                    "You are an AI Knowledge Companion. Answer the user's question accurately based on the session."
                },
                isThinkingMode = isThinkingMode,
                isFastMode = isFastMode
            )
            res.onSuccess { (text, model) ->
                responseContent = text
                modelUsed = model
            }
        } else {
            if (isThinkingMode) {
                val res = com.example.data.gemini.GeminiClient.generateHighThinkingResponse(
                    prompt = promptContext,
                    systemPrompt = "You are an AI Deep Strategist. Use rigorous high-level thinking to analyze this knowledge session comprehensively and answer the query."
                )
                res.onSuccess {
                    responseContent = it
                    modelUsed = "gemini-3.1-pro-preview (High Thinking)"
                }
            } else if (isFastMode) {
                val res = com.example.data.gemini.GeminiClient.generateFastResponse(
                    prompt = promptContext,
                    systemPrompt = "You are a low-latency AI Knowledge Copilot. Answer rapidly and clearly."
                )
                res.onSuccess {
                    responseContent = it
                    modelUsed = "gemini-3.1-flash-lite"
                }
            }
        }

        val assistantMsg = if (responseContent != null) {
            ChatMessage(
                id = "chat_${UUID.randomUUID().toString().take(8)}",
                sessionId = session.id,
                role = ChatRole.ASSISTANT,
                content = responseContent!!,
                citations = listOf("[session: ${session.title}]", "[model: $modelUsed]"),
                confidence = 0.98,
                promptVersions = mapOf("model" to modelUsed, "version" to "1.0"),
                createdAt = System.currentTimeMillis()
            )
        } else {
            AiKnowledgeEngine.answerChat(session, userText, emptyList())
        }

        db.chatMessageDao().insert(
            ChatMessageEntity(
                id = assistantMsg.id,
                sessionId = assistantMsg.sessionId,
                role = "assistant",
                content = assistantMsg.content,
                citationsJson = JsonUtils.serializeStringList(assistantMsg.citations),
                confidence = assistantMsg.confidence,
                promptVersionsJson = JsonUtils.serializeStringMap(assistantMsg.promptVersions),
                createdAt = assistantMsg.createdAt
            )
        )
    }

    // Drafts / AI Commands
    fun getDraftsForSession(sessionId: String): Flow<List<CommandDraft>> =
        db.commandDraftDao().getDraftsForSessionFlow(sessionId).map { list ->
            list.map {
                CommandDraft(
                    id = it.id,
                    sessionId = it.sessionId,
                    command = it.command,
                    title = it.title,
                    body = it.body,
                    items = JsonUtils.deserializeDraftItems(it.itemsJson),
                    promptVersions = JsonUtils.deserializeStringMap(it.promptVersionsJson),
                    createdAt = it.createdAt,
                    updatedAt = it.updatedAt
                )
            }
        }

    suspend fun runCommand(commandName: String, session: Session): CommandDraft = withContext(Dispatchers.IO) {
        val draft = AiKnowledgeEngine.executeCommand(commandName, session)
        db.commandDraftDao().insert(
            CommandDraftEntity(
                id = draft.id,
                sessionId = draft.sessionId,
                command = draft.command,
                title = draft.title,
                body = draft.body,
                itemsJson = JsonUtils.serializeDraftItems(draft.items),
                promptVersionsJson = JsonUtils.serializeStringMap(draft.promptVersions),
                createdAt = draft.createdAt,
                updatedAt = draft.updatedAt
            )
        )
        draft
    }

    suspend fun saveDraft(draft: CommandDraft) = withContext(Dispatchers.IO) {
        db.commandDraftDao().insert(
            CommandDraftEntity(
                id = draft.id,
                sessionId = draft.sessionId,
                command = draft.command,
                title = draft.title,
                body = draft.body,
                itemsJson = JsonUtils.serializeDraftItems(draft.items),
                promptVersionsJson = JsonUtils.serializeStringMap(draft.promptVersions),
                createdAt = draft.createdAt,
                updatedAt = System.currentTimeMillis()
            )
        )
    }

    suspend fun deleteDraft(id: String) = withContext(Dispatchers.IO) {
        db.commandDraftDao().deleteById(id)
    }

    suspend fun saveDraftToSession(session: Session, draft: CommandDraft) = withContext(Dispatchers.IO) {
        if (draft.items.isNotEmpty()) {
            val newTopic = Topic(
                id = "topic_${UUID.randomUUID().toString().take(8)}",
                title = draft.title,
                position = session.topics.size,
                description = "Saved from AI Command: ${draft.command}",
                confidence = 0.95,
                items = draft.items.mapIndexed { idx, item ->
                    Item(
                        id = "item_${UUID.randomUUID().toString().take(8)}",
                        type = item.type ?: ItemType.TASK,
                        title = item.title,
                        description = item.body,
                        position = idx,
                        priority = item.priority ?: Priority.MEDIUM,
                        confidence = item.confidence ?: 0.90
                    )
                }
            )
            val updated = session.copy(
                topics = session.topics + newTopic,
                updatedAt = System.currentTimeMillis(),
                status = SessionStatus.EDITED
            )
            saveSession(updated)
            createVersionSnapshot(updated, "Appended '${draft.title}' topic from AI command")
        }
    }

    suspend fun addEntityToSession(sessionId: String, entity: GraphEntity) = withContext(Dispatchers.IO) {
        val session = getSessionById(sessionId) ?: return@withContext
        val updatedEntities = (session.entities.filter { it.id != entity.id } + entity)
        val updated = session.copy(entities = updatedEntities, updatedAt = System.currentTimeMillis())
        saveSession(updated)
        createVersionSnapshot(updated, "Added entity '${entity.name}'")
    }

    suspend fun addRelationshipToSession(sessionId: String, relation: GraphRelation) = withContext(Dispatchers.IO) {
        val session = getSessionById(sessionId) ?: return@withContext
        val updatedRels = (session.relationships.filter { it.id != relation.id } + relation)
        val updated = session.copy(relationships = updatedRels, updatedAt = System.currentTimeMillis())
        saveSession(updated)
        createVersionSnapshot(updated, "Added relationship '${relation.type.label}'")
    }

    suspend fun saveBatchSession(documents: List<Pair<String, String>>): Session = withContext(Dispatchers.IO) {
        val session = AiKnowledgeEngine.analyzeMultiDocumentBatch(documents)
        saveSession(session)
        createVersionSnapshot(session, "Created multi-document batch session (${documents.size} files)")
        session
    }

    // Plugins
    val plugins: Flow<List<PluginTargetStatus>> = db.pluginSettingDao().getAllPluginsFlow().map { list ->
        list.map { PluginTargetStatus(it.kind, it.displayName, it.connected, it.configured, it.iconName) }
    }

    suspend fun togglePlugin(kind: String, connected: Boolean) = withContext(Dispatchers.IO) {
        db.pluginSettingDao().setConnected(kind, connected)
    }

    suspend fun clearAllSessions() = withContext(Dispatchers.IO) {
        db.sessionDao().getAllSessionsList().forEach {
            db.sessionDao().hardDelete(it.id)
        }
    }

    companion object {
        @Volatile
        private var INSTANCE: KnowledgeRepository? = null

        fun getInstance(context: Context): KnowledgeRepository {
            return INSTANCE ?: synchronized(this) {
                val db = AppDatabase.getDatabase(context)
                val repo = KnowledgeRepository(db, context.applicationContext)
                INSTANCE = repo
                repo
            }
        }
    }
}
private fun Session.copyWith(updatedAt: Long): Session = this.copy(updatedAt = updatedAt)
