package com.example.ui.navigation

sealed class Screen(val route: String) {
    data object Home : Screen("home")
    data object Recording : Screen("recording")
    data object NoteEditor : Screen("note_editor")
    data object DocumentCapture : Screen("document_capture")
    data object SessionDetail : Screen("session_detail/{sessionId}") {
        fun createRoute(sessionId: String) = "session_detail/$sessionId"
    }
    data object GlobalGraph : Screen("global_graph")
    data object Insights : Screen("insights")
    data object GlobalChat : Screen("global_chat")
    data object ExecutiveSynthesis : Screen("executive_synthesis")
    data object Search : Screen("search")
    data object DraftDetail : Screen("draft_detail/{sessionId}/{draftId}") {
        fun createRoute(sessionId: String, draftId: String) = "draft_detail/$sessionId/$draftId"
    }
    data object VersionHistory : Screen("version_history/{sessionId}") {
        fun createRoute(sessionId: String) = "version_history/$sessionId"
    }
    data object Settings : Screen("settings")
}
