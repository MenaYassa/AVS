package com.example.data.local

import androidx.room.*
import kotlinx.coroutines.flow.Flow

@Dao
interface SessionDao {
    @Query("SELECT * FROM sessions WHERE deleted = 0 ORDER BY pinned DESC, updatedAt DESC")
    fun getAllSessionsFlow(): Flow<List<SessionEntity>>

    @Query("SELECT * FROM sessions WHERE id = :id AND deleted = 0 LIMIT 1")
    suspend fun getSessionById(id: String): SessionEntity?

    @Query("SELECT * FROM sessions WHERE id = :id AND deleted = 0 LIMIT 1")
    fun getSessionByIdFlow(id: String): Flow<SessionEntity?>

    @Query("SELECT * FROM sessions WHERE deleted = 0")
    suspend fun getAllSessionsList(): List<SessionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertOrUpdate(session: SessionEntity)

    @Update
    suspend fun update(session: SessionEntity)

    @Query("UPDATE sessions SET favorite = :favorite, updatedAt = :updatedAt WHERE id = :id")
    suspend fun setFavorite(id: String, favorite: Boolean, updatedAt: Long)

    @Query("UPDATE sessions SET pinned = :pinned, updatedAt = :updatedAt WHERE id = :id")
    suspend fun setPinned(id: String, pinned: Boolean, updatedAt: Long)

    @Query("UPDATE sessions SET archived = :archived, updatedAt = :updatedAt WHERE id = :id")
    suspend fun setArchived(id: String, archived: Boolean, updatedAt: Long)

    @Query("UPDATE sessions SET deleted = 1, updatedAt = :updatedAt WHERE id = :id")
    suspend fun softDelete(id: String, updatedAt: Long)

    @Query("UPDATE sessions SET deleted = 0, updatedAt = :updatedAt WHERE id = :id")
    suspend fun undelete(id: String, updatedAt: Long)

    @Query("DELETE FROM sessions WHERE id = :id")
    suspend fun hardDelete(id: String)
}

@Dao
interface SessionVersionDao {
    @Query("SELECT * FROM session_versions WHERE sessionId = :sessionId ORDER BY versionNumber DESC")
    fun getVersionsForSessionFlow(sessionId: String): Flow<List<SessionVersionEntity>>

    @Query("SELECT * FROM session_versions WHERE id = :id LIMIT 1")
    suspend fun getVersionById(id: String): SessionVersionEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(version: SessionVersionEntity)
}

@Dao
interface ChatMessageDao {
    @Query("SELECT * FROM chat_messages WHERE sessionId = :sessionId ORDER BY createdAt ASC")
    fun getMessagesForSessionFlow(sessionId: String): Flow<List<ChatMessageEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(message: ChatMessageEntity)

    @Query("DELETE FROM chat_messages WHERE sessionId = :sessionId")
    suspend fun deleteForSession(sessionId: String)
}

@Dao
interface CommandDraftDao {
    @Query("SELECT * FROM command_drafts WHERE sessionId = :sessionId ORDER BY updatedAt DESC")
    fun getDraftsForSessionFlow(sessionId: String): Flow<List<CommandDraftEntity>>

    @Query("SELECT * FROM command_drafts WHERE id = :id LIMIT 1")
    suspend fun getDraftById(id: String): CommandDraftEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(draft: CommandDraftEntity)

    @Query("DELETE FROM command_drafts WHERE id = :id")
    suspend fun deleteById(id: String)
}

@Dao
interface PluginSettingDao {
    @Query("SELECT * FROM plugin_settings")
    fun getAllPluginsFlow(): Flow<List<PluginSettingEntity>>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(plugins: List<PluginSettingEntity>)

    @Query("UPDATE plugin_settings SET connected = :connected WHERE kind = :kind")
    suspend fun setConnected(kind: String, connected: Boolean)
}

@Dao
interface AppSettingDao {
    @Query("SELECT * FROM app_settings")
    fun getAllSettingsFlow(): Flow<List<AppSettingEntity>>

    @Query("SELECT value FROM app_settings WHERE key = :key LIMIT 1")
    suspend fun getValue(key: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun setValue(setting: AppSettingEntity)
}
