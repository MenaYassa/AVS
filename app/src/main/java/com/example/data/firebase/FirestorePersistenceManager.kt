package com.example.data.firebase

import android.content.Context
import android.util.Log
import com.example.data.local.AppDatabase
import com.example.data.local.JsonUtils
import com.example.data.model.*
import com.example.data.repository.KnowledgeRepository
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withContext

sealed interface SyncStatus {
    object Idle : SyncStatus
    object Syncing : SyncStatus
    data class Success(val lastSyncTime: Long) : SyncStatus
    data class Error(val message: String) : SyncStatus
}

class FirestorePersistenceManager(
    private val context: Context,
    private val repository: KnowledgeRepository
) {
    private val TAG = "FirestoreSync"

    private val firestore: FirebaseFirestore? by lazy {
        try {
            FirebaseFirestore.getInstance()
        } catch (e: Exception) {
            Log.w(TAG, "Firestore initialization fallback: ${e.message}")
            null
        }
    }

    private val _syncStatus = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    val syncStatus: StateFlow<SyncStatus> = _syncStatus.asStateFlow()

    /**
     * Pushes a session and its associated topics, items, and knowledge graph to Firestore
     */
    suspend fun pushSession(userId: String, session: Session): Result<Unit> = withContext(Dispatchers.IO) {
        val db = firestore ?: return@withContext Result.success(Unit) // Offline/fallback

        try {
            _syncStatus.value = SyncStatus.Syncing

            val sessionDoc = db.collection("users")
                .document(userId)
                .collection("sessions")
                .document(session.id)

            val sessionData = hashMapOf(
                "id" to session.id,
                "userId" to userId,
                "title" to session.title,
                "summary" to session.summary,
                "summaryConfidence" to session.summaryConfidence,
                "extractionConfidence" to session.extractionConfidence,
                "language" to session.language,
                "status" to session.status.name,
                "durationSec" to session.durationSec,
                "wordCount" to session.wordCount,
                "originalTranscript" to session.originalTranscript,
                "cleanedTranscript" to session.cleanedTranscript,
                "favorite" to session.favorite,
                "archived" to session.archived,
                "deleted" to session.deleted,
                "pinned" to session.pinned,
                "tags" to session.tags,
                "createdAt" to session.createdAt,
                "updatedAt" to session.updatedAt,
                // Also store full structured JSON for rapid cross-device atomic restore
                "topicsJson" to JsonUtils.serializeTopics(session.topics),
                "entitiesJson" to JsonUtils.serializeEntities(session.entities),
                "relationsJson" to JsonUtils.serializeRelationships(session.relationships)
            )

            sessionDoc.set(sessionData, SetOptions.merge()).await()

            // Save topics subcollection for granular Firestore queries
            for (topic in session.topics) {
                val topicDoc = sessionDoc.collection("topics").document(topic.id)
                val topicData = hashMapOf(
                    "id" to topic.id,
                    "title" to topic.title,
                    "position" to topic.position,
                    "description" to topic.description,
                    "confidence" to topic.confidence
                )
                topicDoc.set(topicData, SetOptions.merge()).await()

                // Save items
                for (item in topic.items) {
                    val itemDoc = topicDoc.collection("items").document(item.id)
                    val itemData = hashMapOf(
                        "id" to item.id,
                        "type" to item.type.name,
                        "title" to item.title,
                        "description" to item.description,
                        "position" to item.position,
                        "priority" to (item.priority?.name ?: "MEDIUM"),
                        "confidence" to item.confidence,
                        "completed" to item.completed
                    )
                    itemDoc.set(itemData, SetOptions.merge()).await()
                }
            }

            // Save graph entities
            for (entity in session.entities) {
                val entityDoc = db.collection("users")
                    .document(userId)
                    .collection("entities")
                    .document(entity.id)

                val entityData = hashMapOf(
                    "id" to entity.id,
                    "userId" to userId,
                    "type" to entity.type.name,
                    "name" to entity.name,
                    "canonicalName" to entity.canonicalName,
                    "aliases" to entity.aliases,
                    "confidence" to entity.confidence
                )
                entityDoc.set(entityData, SetOptions.merge()).await()
            }

            // Save graph relations
            for (relation in session.relationships) {
                val relationDoc = db.collection("users")
                    .document(userId)
                    .collection("relations")
                    .document(relation.id)

                val relationData = hashMapOf(
                    "id" to relation.id,
                    "userId" to userId,
                    "sourceId" to relation.sourceId,
                    "targetId" to relation.targetId,
                    "type" to relation.type.name,
                    "weight" to relation.weight,
                    "confidence" to relation.confidence
                )
                relationDoc.set(relationData, SetOptions.merge()).await()
            }

            _syncStatus.value = SyncStatus.Success(System.currentTimeMillis())
            Result.success(Unit)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to push session to Firestore: ${e.message}", e)
            _syncStatus.value = SyncStatus.Error(e.message ?: "Firestore sync failed")
            Result.failure(e)
        }
    }

    /**
     * Restores all sessions and knowledge graph from Firestore into local Room database
     * Enables full cross-device restore on Google Sign-in.
     */
    suspend fun restoreAllFromCloud(userId: String): Result<Int> = withContext(Dispatchers.IO) {
        val db = firestore ?: return@withContext Result.success(0)

        try {
            _syncStatus.value = SyncStatus.Syncing
            val snapshot = db.collection("users")
                .document(userId)
                .collection("sessions")
                .get()
                .await()

            var restoredCount = 0
            for (doc in snapshot.documents) {
                try {
                    val id = doc.getString("id") ?: doc.id
                    val title = doc.getString("title") ?: "Untitled Session"
                    val summary = doc.getString("summary")
                    val summaryConf = doc.getDouble("summaryConfidence") ?: 0.95
                    val extractConf = doc.getDouble("extractionConfidence") ?: 0.92
                    val language = doc.getString("language") ?: "en"
                    val statusStr = doc.getString("status") ?: SessionStatus.READY.name
                    val status = try { SessionStatus.valueOf(statusStr) } catch (e: Exception) { SessionStatus.READY }
                    val durationSec = doc.getDouble("durationSec") ?: doc.getLong("durationSec")?.toDouble()
                    val wordCount = doc.getLong("wordCount")?.toInt() ?: 0
                    val originalTranscript = doc.getString("originalTranscript") ?: ""
                    val cleanedTranscript = doc.getString("cleanedTranscript") ?: ""
                    val favorite = doc.getBoolean("favorite") ?: false
                    val archived = doc.getBoolean("archived") ?: false
                    val deleted = doc.getBoolean("deleted") ?: false
                    val pinned = doc.getBoolean("pinned") ?: false
                    val tags = (doc.get("tags") as? List<*>)?.filterIsInstance<String>() ?: emptyList()
                    val createdAt = doc.getLong("createdAt") ?: System.currentTimeMillis()
                    val updatedAt = doc.getLong("updatedAt") ?: System.currentTimeMillis()

                    val topicsJson = doc.getString("topicsJson")
                    val entitiesJson = doc.getString("entitiesJson")
                    val relationsJson = doc.getString("relationsJson")

                    val topics: List<Topic> = if (!topicsJson.isNullOrBlank()) {
                        JsonUtils.deserializeTopics(topicsJson)
                    } else {
                        emptyList()
                    }

                    val entities: List<GraphEntity> = if (!entitiesJson.isNullOrBlank()) {
                        JsonUtils.deserializeEntities(entitiesJson)
                    } else {
                        emptyList()
                    }

                    val relations: List<GraphRelation> = if (!relationsJson.isNullOrBlank()) {
                        JsonUtils.deserializeRelationships(relationsJson)
                    } else {
                        emptyList()
                    }

                    val session = Session(
                        id = id,
                        title = title,
                        summary = summary,
                        summaryConfidence = summaryConf,
                        extractionConfidence = extractConf,
                        language = language,
                        status = status,
                        durationSec = durationSec,
                        wordCount = wordCount,
                        originalTranscript = originalTranscript,
                        cleanedTranscript = cleanedTranscript,
                        favorite = favorite,
                        archived = archived,
                        deleted = deleted,
                        pinned = pinned,
                        tags = tags,
                        createdAt = createdAt,
                        updatedAt = updatedAt,
                        topics = topics,
                        entities = entities,
                        relationships = relations
                    )

                    repository.saveSession(session)
                    restoredCount++
                } catch (itemErr: Exception) {
                    Log.w(TAG, "Error restoring individual session: ${itemErr.message}")
                }
            }

            _syncStatus.value = SyncStatus.Success(System.currentTimeMillis())
            Result.success(restoredCount)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restore from Firestore: ${e.message}", e)
            _syncStatus.value = SyncStatus.Error(e.message ?: "Restore failed")
            Result.failure(e)
        }
    }

    /**
     * Performs a full sync of all local sessions to Firestore
     */
    suspend fun syncAll(userId: String): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            _syncStatus.value = SyncStatus.Syncing
            val sessions = repository.getAllSessionsList()
            for (session in sessions) {
                pushSession(userId, session)
            }
            _syncStatus.value = SyncStatus.Success(System.currentTimeMillis())
            Result.success(Unit)
        } catch (e: Exception) {
            _syncStatus.value = SyncStatus.Error(e.message ?: "Sync all failed")
            Result.failure(e)
        }
    }
}
