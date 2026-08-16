package com.example.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

@Database(
    entities = [
        SessionEntity::class,
        SessionVersionEntity::class,
        ChatMessageEntity::class,
        CommandDraftEntity::class,
        PluginSettingEntity::class,
        AppSettingEntity::class
    ],
    version = 1,
    exportSchema = false
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun sessionDao(): SessionDao
    abstract fun sessionVersionDao(): SessionVersionDao
    abstract fun chatMessageDao(): ChatMessageDao
    abstract fun commandDraftDao(): CommandDraftDao
    abstract fun pluginSettingDao(): PluginSettingDao
    abstract fun appSettingDao(): AppSettingDao

    companion object {
        @Volatile
        private var INSTANCE: AppDatabase? = null

        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    "ai_knowledge_companion.db"
                )
                    .addCallback(DatabaseCallback())
                    .build()
                INSTANCE = instance
                instance
            }
        }

        private class DatabaseCallback : Callback() {
            override fun onCreate(db: SupportSQLiteDatabase) {
                super.onCreate(db)
                // Seed initial plugins and settings
                INSTANCE?.let { database ->
                    CoroutineScope(Dispatchers.IO).launch {
                        seedDatabase(database)
                    }
                }
            }

            private suspend fun seedDatabase(db: AppDatabase) {
                db.pluginSettingDao().insertAll(
                    listOf(
                        PluginSettingEntity("notion", "Notion Workspace", connected = false, configured = true, iconName = "notion"),
                        PluginSettingEntity("slack", "Slack Channels", connected = false, configured = true, iconName = "slack")
                    )
                )
                db.appSettingDao().setValue(AppSettingEntity("stt_provider", "Whisper Local / Cloud"))
                db.appSettingDao().setValue(AppSettingEntity("llm_provider", "Gemini 2.5 Flash"))
                db.appSettingDao().setValue(AppSettingEntity("privacy_mode", "Local First (Encrypted)"))
                db.appSettingDao().setValue(AppSettingEntity("auto_delete_audio", "false"))
                db.appSettingDao().setValue(AppSettingEntity("ai_memory_enabled", "true"))
            }
        }
    }
}
