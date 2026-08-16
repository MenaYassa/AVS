package com.example.data.local

import com.example.data.model.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object JsonUtils {
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    fun serializeTopics(topics: List<Topic>): String = json.encodeToString(topics)
    fun deserializeTopics(raw: String): List<Topic> = try {
        if (raw.isBlank()) emptyList() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyList()
    }

    fun serializeEntities(entities: List<GraphEntity>): String = json.encodeToString(entities)
    fun deserializeEntities(raw: String): List<GraphEntity> = try {
        if (raw.isBlank()) emptyList() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyList()
    }

    fun serializeRelationships(relations: List<GraphRelation>): String = json.encodeToString(relations)
    fun deserializeRelationships(raw: String): List<GraphRelation> = try {
        if (raw.isBlank()) emptyList() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyList()
    }

    fun serializeStringList(list: List<String>): String = json.encodeToString(list)
    fun deserializeStringList(raw: String): List<String> = try {
        if (raw.isBlank()) emptyList() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyList()
    }

    fun serializeStringMap(map: Map<String, String>): String = json.encodeToString(map)
    fun deserializeStringMap(raw: String): Map<String, String> = try {
        if (raw.isBlank()) emptyMap() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyMap()
    }

    fun serializeDraftItems(items: List<DraftItem>): String = json.encodeToString(items)
    fun deserializeDraftItems(raw: String): List<DraftItem> = try {
        if (raw.isBlank()) emptyList() else json.decodeFromString(raw)
    } catch (e: Exception) {
        emptyList()
    }

    fun sessionToEntity(session: Session): SessionEntity {
        return SessionEntity(
            id = session.id,
            userId = session.userId,
            title = session.title,
            alternativeTitlesJson = serializeStringList(session.alternativeTitles),
            summary = session.summary,
            summaryConfidence = session.summaryConfidence,
            extractionConfidence = session.extractionConfidence,
            language = session.language,
            status = session.status.name,
            durationSec = session.durationSec,
            wordCount = session.wordCount,
            originalTranscript = session.originalTranscript,
            cleanedTranscript = session.cleanedTranscript,
            audioPath = session.audioPath,
            audioRemoteUrl = session.audioRemoteUrl,
            promptVersionsJson = serializeStringMap(session.promptVersions),
            favorite = session.favorite,
            archived = session.archived,
            deleted = session.deleted,
            pinned = session.pinned,
            tagsJson = serializeStringList(session.tags),
            lastError = session.lastError,
            createdAt = session.createdAt,
            updatedAt = session.updatedAt,
            topicsJson = serializeTopics(session.topics),
            entitiesJson = serializeEntities(session.entities),
            relationshipsJson = serializeRelationships(session.relationships)
        )
    }

    fun entityToSession(entity: SessionEntity): Session {
        val status = try {
            SessionStatus.valueOf(entity.status)
        } catch (e: Exception) {
            SessionStatus.READY
        }
        return Session(
            id = entity.id,
            userId = entity.userId,
            title = entity.title,
            alternativeTitles = deserializeStringList(entity.alternativeTitlesJson),
            summary = entity.summary,
            summaryConfidence = entity.summaryConfidence,
            extractionConfidence = entity.extractionConfidence,
            language = entity.language,
            status = status,
            durationSec = entity.durationSec,
            wordCount = entity.wordCount,
            originalTranscript = entity.originalTranscript,
            cleanedTranscript = entity.cleanedTranscript,
            audioPath = entity.audioPath,
            audioRemoteUrl = entity.audioRemoteUrl,
            promptVersions = deserializeStringMap(entity.promptVersionsJson),
            favorite = entity.favorite,
            archived = entity.archived,
            deleted = entity.deleted,
            pinned = entity.pinned,
            tags = deserializeStringList(entity.tagsJson),
            lastError = entity.lastError,
            createdAt = entity.createdAt,
            updatedAt = entity.updatedAt,
            topics = deserializeTopics(entity.topicsJson),
            entities = deserializeEntities(entity.entitiesJson),
            relationships = deserializeRelationships(entity.relationshipsJson)
        )
    }
}
