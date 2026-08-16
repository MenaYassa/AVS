package com.example.ui.note

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class NoteEditorViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _isAnalyzing = MutableStateFlow(false)
    val isAnalyzing: StateFlow<Boolean> = _isAnalyzing.asStateFlow()

    fun analyzeAndSave(title: String, content: String, onComplete: (String) -> Unit) {
        if (content.isBlank()) return
        _isAnalyzing.value = true

        viewModelScope.launch {
            val session = AiKnowledgeEngine.analyze(
                rawText = if (title.isNotBlank()) "$title\n\n$content" else content,
                audioDurationSec = 0.0
            )
            val customizedSession = if (title.isNotBlank()) session.copy(title = title) else session

            repository.saveSession(customizedSession)
            repository.createVersionSnapshot(customizedSession, "Initial Note AI Analysis")
            _isAnalyzing.value = false
            onComplete(customizedSession.id)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteEditorScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: NoteEditorViewModel = viewModel()
) {
    var title by remember { mutableStateOf("") }
    var content by remember {
        mutableStateOf(
            "Met with David and Elena to finalize the Supabase pgvector embedding schema. We agreed on using cosine similarity with 768 dimensions. Action item: David to write the migration script by Wednesday. What is our rollback strategy if the migration times out?"
        )
    }
    val isAnalyzing by viewModel.isAnalyzing.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("Write a Note", fontWeight = FontWeight.Bold, color = TextPrimary)
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("note_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    Button(
                        onClick = {
                            viewModel.analyzeAndSave(title, content) { sessionId ->
                                onNavigateToSession(sessionId)
                            }
                        },
                        enabled = content.isNotBlank() && !isAnalyzing,
                        colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier
                            .padding(end = 12.dp)
                            .testTag("analyze_note_btn")
                    ) {
                        if (isAnalyzing) {
                            CircularProgressIndicator(
                                color = Color.White,
                                strokeWidth = 2.dp,
                                modifier = Modifier.size(16.dp)
                            )
                        } else {
                            Icon(Icons.Default.AutoAwesome, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Synthesize", fontWeight = FontWeight.Bold)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = DeepSlate)
            )
        },
        containerColor = DeepSlate
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(horizontal = 20.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // Quick template buttons
            Text(
                text = "Templates",
                style = MaterialTheme.typography.labelSmall,
                color = TextSecondary,
                fontWeight = FontWeight.SemiBold
            )
            Spacer(modifier = Modifier.height(6.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                AssistChip(
                    onClick = {
                        title = "Engineering Architecture Sync"
                        content = "Discussed microservice migration with Alex and Sarah. Agreed to use gRPC for internal service calls to reduce overhead. Need to benchmark latency before rollout."
                    },
                    label = { Text("Arch Sync", fontSize = 12.sp) }
                )
                AssistChip(
                    onClick = {
                        title = "Product Strategy & 1:1"
                        content = "Reviewed Q3 milestones with Elena. Action items: finalize Notion plugin integration, review onboarding conversion metrics, schedule user research sessions."
                    },
                    label = { Text("Product 1:1", fontSize = 12.sp) }
                )
                AssistChip(
                    onClick = {
                        title = "Sprint Retrospective Takeaways"
                        content = "Identified bottleneck in CI build pipeline. Decided to enable remote caching. Action item: update GitHub actions workflow by Friday."
                    },
                    label = { Text("Retro", fontSize = 12.sp) }
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Title Field
            OutlinedTextField(
                value = title,
                onValueChange = { title = it },
                placeholder = { Text("Note Title (Optional — AI can generate one)", color = TextMuted) },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = SurfaceDark,
                    unfocusedContainerColor = SurfaceDark,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("note_title_input")
            )

            Spacer(modifier = Modifier.height(14.dp))

            // Body Field
            OutlinedTextField(
                value = content,
                onValueChange = { content = it },
                placeholder = { Text("Write your thoughts, raw meeting minutes, or brainstormed ideas...", color = TextMuted) },
                minLines = 12,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = SurfaceDark,
                    unfocusedContainerColor = SurfaceDark,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("note_content_input")
            )

            Spacer(modifier = Modifier.height(18.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.6f)),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.padding(14.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.AutoAwesome,
                        contentDescription = null,
                        tint = IndigoLight,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(modifier = Modifier.width(10.dp))
                    Text(
                        text = "The AI Knowledge Engine extracts decisions, action items, tags, entities, and relationships automatically from your text.",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                        fontSize = 12.sp
                    )
                }
            }
        }
    }
}
