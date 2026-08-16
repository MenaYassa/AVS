package com.example.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "sessions")
data class SessionEntity(
    @PrimaryKey val id: String,
    val userId: String,
    val title: String?,
    val alternativeTitlesJson: String,
    val summary: String?,
    val summaryConfidence: Double?,
    val extractionConfidence: Double?,
    val language: String?,
    val status: String,
    val durationSec: Double?,
    val wordCount: Int?,
    val originalTranscript: String?,
    val cleanedTranscript: String?,
    val audioPath: String?,
    val audioRemoteUrl: String?,
    val promptVersionsJson: String,
    val favorite: Boolean,
    val archived: Boolean,
    val deleted: Boolean,
    val pinned: Boolean,
    val tagsJson: String,
    val lastError: String?,
    val createdAt: Long,
    val updatedAt: Long,
    val topicsJson: String,
    val entitiesJson: String,
    val relationshipsJson: String
)

@Entity(tableName = "session_versions")
data class SessionVersionEntity(
    @PrimaryKey val id: String,
    val sessionId: String,
    val versionNumber: Int,
    val title: String,
    val snapshotJson: String,
    val changeDescription: String,
    val createdAt: Long
)

@Entity(tableName = "chat_messages")
data class ChatMessageEntity(
    @PrimaryKey val id: String,
    val sessionId: String,
    val role: String,
    val content: String,
    val citationsJson: String,
    val confidence: Double?,
    val promptVersionsJson: String,
    val createdAt: Long
)

@Entity(tableName = "command_drafts")
data class CommandDraftEntity(
    @PrimaryKey val id: String,
    val sessionId: String,
    val command: String,
    val title: String,
    val body: String,
    val itemsJson: String,
    val promptVersionsJson: String,
    val createdAt: Long,
    val updatedAt: Long
)

@Entity(tableName = "plugin_settings")
data class PluginSettingEntity(
    @PrimaryKey val kind: String,
    val displayName: String,
    val connected: Boolean,
    val configured: Boolean,
    val iconName: String
)

@Entity(tableName = "app_settings")
data class AppSettingEntity(
    @PrimaryKey val key: String,
    val value: String
)
