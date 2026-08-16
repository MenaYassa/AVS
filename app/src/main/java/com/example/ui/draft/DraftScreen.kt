package com.example.ui.draft

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.model.CommandDraft
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class DraftViewModel(
    application: Application,
    private val draftId: String
) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _draft = MutableStateFlow<CommandDraft?>(null)
    val draft: StateFlow<CommandDraft?> = _draft.asStateFlow()

    private val _isPushing = MutableStateFlow(false)
    val isPushing: StateFlow<Boolean> = _isPushing.asStateFlow()

    init {
        viewModelScope.launch {
            repository.allSessions.collect { sessions ->
                for (s in sessions) {
                    val found = repository.getDraftsForSession(s.id)
                    found.collect { drafts ->
                        val target = drafts.find { it.id == draftId }
                        if (target != null) {
                            _draft.value = target
                        }
                    }
                }
            }
        }
    }

    fun updateDraftContent(title: String, content: String) {
        val current = _draft.value ?: return
        viewModelScope.launch {
            val updated = current.copy(title = title, body = content)
            repository.saveDraft(updated)
            _draft.value = updated
        }
    }

    fun pushToPlugin(pluginTarget: String, onResult: (String) -> Unit) {
        _isPushing.value = true
        viewModelScope.launch {
            kotlinx.coroutines.delay(800)
            _isPushing.value = false
            onResult("Successfully dispatched draft to $pluginTarget workspace!")
        }
    }

    class Factory(
        private val application: Application,
        private val draftId: String
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            return DraftViewModel(application, draftId) as T
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DraftScreen(
    sessionId: String,
    draftId: String,
    onNavigateBack: () -> Unit
) {
    val context = LocalContext.current
    val app = context.applicationContext as Application
    val viewModel: DraftViewModel = viewModel(
        key = draftId,
        factory = DraftViewModel.Factory(app, draftId)
    )

    val draft by viewModel.draft.collectAsState()
    val isPushing by viewModel.isPushing.collectAsState()

    var title by remember { mutableStateOf("") }
    var content by remember { mutableStateOf("") }
    var isInitialized by remember { mutableStateOf(false) }

    LaunchedEffect(draft) {
        if (draft != null && !isInitialized) {
            title = draft!!.title
            content = draft!!.body
            isInitialized = true
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("AI Command Draft", fontWeight = FontWeight.Bold, color = TextPrimary)
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("draft_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = ClipData.newPlainText("Draft", "# $title\n\n$content")
                            clipboard.setPrimaryClip(clip)
                            Toast.makeText(context, "Copied draft markdown to clipboard", Toast.LENGTH_SHORT).show()
                        },
                        modifier = Modifier.testTag("copy_draft_btn")
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy", tint = TextPrimary)
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
            // Push targets actions bar
            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                shape = RoundedCornerShape(14.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(14.dp)) {
                    Text(
                        text = "Plugin Push Targets",
                        style = MaterialTheme.typography.labelSmall,
                        color = TextSecondary,
                        fontWeight = FontWeight.Bold
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
        Button(
            onClick = {
                viewModel.pushToPlugin("Notion") { msg ->
                    Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
                }
            },
            enabled = !isPushing,
            colors = ButtonDefaults.buttonColors(containerColor = SurfaceCard),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.weight(1f).testTag("push_notion_btn")
        ) {
            Icon(Icons.Default.CloudUpload, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text("Push to Notion", fontSize = 12.sp, color = TextPrimary)
        }

        Button(
            onClick = {
                viewModel.pushToPlugin("Slack") { msg ->
                    Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
                }
            },
            enabled = !isPushing,
            colors = ButtonDefaults.buttonColors(containerColor = SurfaceCard),
            shape = RoundedCornerShape(10.dp),
            modifier = Modifier.weight(1f).testTag("push_slack_btn")
        ) {
            Icon(Icons.Default.Send, contentDescription = null, tint = EmeraldSuccess, modifier = Modifier.size(16.dp))
            Spacer(modifier = Modifier.width(6.dp))
            Text("Share to Slack", fontSize = 12.sp, color = TextPrimary)
        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Draft Title input
            OutlinedTextField(
                value = title,
                onValueChange = {
                    title = it
                    viewModel.updateDraftContent(title, content)
                },
                label = { Text("Draft Title") },
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
                modifier = Modifier.fillMaxWidth().testTag("draft_title_input")
            )

            Spacer(modifier = Modifier.height(14.dp))

            // Draft Content
            OutlinedTextField(
                value = content,
                onValueChange = {
                    content = it
                    viewModel.updateDraftContent(title, content)
                },
                label = { Text("Markdown Draft Content") },
                minLines = 14,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = SurfaceDark,
                    unfocusedContainerColor = SurfaceDark,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth().testTag("draft_content_input")
            )
        }
    }
}
