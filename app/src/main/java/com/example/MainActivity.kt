package com.example

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.example.ui.capture.DocumentCaptureScreen
import com.example.ui.detail.SessionDetailScreen
import com.example.ui.draft.DraftScreen
import com.example.ui.graph.GlobalGraphScreen
import com.example.ui.home.HomeScreen
import com.example.ui.insights.InsightsScreen
import com.example.ui.navigation.Screen
import com.example.ui.note.NoteEditorScreen
import com.example.ui.recording.RecordingScreen
import com.example.ui.settings.SettingsScreen
import com.example.ui.theme.DeepSlate
import com.example.ui.theme.KnowledgeCompanionTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            KnowledgeCompanionTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = DeepSlate
                ) {
                    AppNavigation()
                }
            }
        }
    }
}

@Composable
fun AppNavigation() {
    val navController = rememberNavController()

    NavHost(
        navController = navController,
        startDestination = Screen.Home.route
    ) {
        // Home Dashboard
        composable(Screen.Home.route) {
            HomeScreen(
                onNavigateToRecord = {
                    navController.navigate(Screen.Recording.route)
                },
                onNavigateToNote = {
                    navController.navigate(Screen.NoteEditor.route)
                },
                onNavigateToCapture = {
                    navController.navigate(Screen.DocumentCapture.route)
                },
                onNavigateToSession = { sessionId ->
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                },
                onNavigateToGlobalGraph = {
                    navController.navigate(Screen.GlobalGraph.route)
                },
                onNavigateToInsights = {
                    navController.navigate(Screen.Insights.route)
                },
                onNavigateToSettings = {
                    navController.navigate(Screen.Settings.route)
                },
                onNavigateToGlobalChat = {
                    navController.navigate(Screen.GlobalChat.route)
                },
                onNavigateToSynthesis = {
                    navController.navigate(Screen.ExecutiveSynthesis.route)
                }
            )
        }

        // Live Voice Recording Screen
        composable(Screen.Recording.route) {
            RecordingScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.popBackStack()
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Note Editor Screen
        composable(Screen.NoteEditor.route) {
            NoteEditorScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.popBackStack()
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Document / OCR Capture Screen
        composable(Screen.DocumentCapture.route) {
            DocumentCaptureScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.popBackStack()
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Session Detail Screen
        composable(
            route = Screen.SessionDetail.route,
            arguments = listOf(navArgument("sessionId") { type = NavType.StringType })
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString("sessionId") ?: ""
            SessionDetailScreen(
                sessionId = sessionId,
                onNavigateBack = { navController.popBackStack() },
                onNavigateToDraft = { sId, dId ->
                    navController.navigate(Screen.DraftDetail.createRoute(sId, dId))
                }
            )
        }

        // Draft Detail Screen
        composable(
            route = Screen.DraftDetail.route,
            arguments = listOf(
                navArgument("sessionId") { type = NavType.StringType },
                navArgument("draftId") { type = NavType.StringType }
            )
        ) { backStackEntry ->
            val sessionId = backStackEntry.arguments?.getString("sessionId") ?: ""
            val draftId = backStackEntry.arguments?.getString("draftId") ?: ""
            DraftScreen(
                sessionId = sessionId,
                draftId = draftId,
                onNavigateBack = { navController.popBackStack() }
            )
        }

        // Global Knowledge Graph Browser
        composable(Screen.GlobalGraph.route) {
            GlobalGraphScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Cross-Session Insights
        composable(Screen.Insights.route) {
            InsightsScreen(
                onNavigateBack = { navController.popBackStack() }
            )
        }

        // Global RAG Copilot / Ask Knowledge Base
        composable(Screen.GlobalChat.route) {
            com.example.ui.chat.GlobalChatScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Cross-Session Executive Synthesis & Conflict Detector
        composable(Screen.ExecutiveSynthesis.route) {
            com.example.ui.synthesis.ExecutiveSynthesisScreen(
                onNavigateBack = { navController.popBackStack() },
                onNavigateToSession = { sessionId ->
                    navController.navigate(Screen.SessionDetail.createRoute(sessionId))
                }
            )
        }

        // Settings & Integrations
        composable(Screen.Settings.route) {
            SettingsScreen(
                onNavigateBack = { navController.popBackStack() }
            )
        }
    }
}
