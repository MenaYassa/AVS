package com.example.ui.synthesis

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.model.ConflictInsight
import com.example.data.model.Session
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class ExecutiveSynthesisViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _sessions = MutableStateFlow<List<Session>>(emptyList())
    val sessions: StateFlow<List<Session>> = _sessions.asStateFlow()

    private val _synthesisText = MutableStateFlow("")
    val synthesisText: StateFlow<String> = _synthesisText.asStateFlow()

    private val _conflicts = MutableStateFlow<List<ConflictInsight>>(emptyList())
    val conflicts: StateFlow<List<ConflictInsight>> = _conflicts.asStateFlow()

    private val _isGenerating = MutableStateFlow(false)
    val isGenerating: StateFlow<Boolean> = _isGenerating.asStateFlow()

    init {
        viewModelScope.launch {
            repository.allSessions.collect { list ->
                _sessions.value = list
                generateSynthesis(list)
            }
        }
    }

    fun generateSynthesis(sessionsList: List<Session> = _sessions.value) {
        _isGenerating.value = true
        viewModelScope.launch {
            kotlinx.coroutines.delay(600)
            _synthesisText.value = AiKnowledgeEngine.generateExecutiveWeeklyBrief(sessionsList)
            _conflicts.value = AiKnowledgeEngine.detectConflictsAndContradictions(sessionsList)
            _isGenerating.value = false
        }
    }
}

enum class SynthesisTab(val label: String) {
    EXECUTIVE_BRIEF("Executive Brief"),
    CONFLICTS("Conflicts & Contradictions")
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ExecutiveSynthesisScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: ExecutiveSynthesisViewModel = viewModel()
) {
    val context = LocalContext.current
    val sessions by viewModel.sessions.collectAsState()
    val synthesisText by viewModel.synthesisText.collectAsState()
    val conflicts by viewModel.conflicts.collectAsState()
    val isGenerating by viewModel.isGenerating.collectAsState()

    var selectedTab by remember { mutableStateOf(SynthesisTab.EXECUTIVE_BRIEF) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Executive Synthesis", fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 18.sp)
                        Text(
                            text = "${sessions.size} sessions analyzed",
                            fontSize = 11.sp,
                            color = TextSecondary
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("synthesis_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    IconButton(
                        onClick = {
                            val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            val clip = ClipData.newPlainText("Executive Synthesis", synthesisText)
                            clipboard.setPrimaryClip(clip)
                            Toast.makeText(context, "Copied Executive Synthesis to clipboard", Toast.LENGTH_SHORT).show()
                        },
                        modifier = Modifier.testTag("copy_synthesis_btn")
                    ) {
                        Icon(Icons.Default.ContentCopy, contentDescription = "Copy", tint = TextPrimary)
                    }
                    IconButton(onClick = { viewModel.generateSynthesis() }) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = IndigoLight)
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
        ) {
            // Tab Row
            TabRow(
                selectedTabIndex = selectedTab.ordinal,
                containerColor = SurfaceDark,
                contentColor = IndigoLight
            ) {
                SynthesisTab.entries.forEach { tab ->
                    Tab(
                        selected = selectedTab == tab,
                        onClick = { selectedTab = tab },
                        text = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    tab.label,
                                    fontWeight = if (selectedTab == tab) FontWeight.Bold else FontWeight.Normal,
                                    fontSize = 13.sp
                                )
                                if (tab == SynthesisTab.CONFLICTS && conflicts.isNotEmpty()) {
                                    Spacer(modifier = Modifier.width(6.dp))
                                    Badge(containerColor = AmberWarning) {
                                        Text("${conflicts.size}", fontSize = 10.sp, color = DeepSlate)
                                    }
                                }
                            }
                        }
                    )
                }
            }

            if (isGenerating) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        CircularProgressIndicator(color = IndigoLight)
                        Spacer(modifier = Modifier.height(14.dp))
                        Text("Synthesizing cross-session intelligence...", color = TextSecondary, fontSize = 13.sp)
                    }
                }
            } else {
                when (selectedTab) {
                    SynthesisTab.EXECUTIVE_BRIEF -> {
                        Column(
                            modifier = Modifier
                                .fillMaxSize()
                                .padding(16.dp)
                                .verticalScroll(rememberScrollState())
                        ) {
                            // Push Bar
                            Card(
                                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Icon(Icons.Default.CloudUpload, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(18.dp))
                                        Spacer(modifier = Modifier.width(8.dp))
                                        Text("Push Brief to Team (§6.3)", fontSize = 12.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
                                    }
                                    Row(
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Button(
                                            onClick = { Toast.makeText(context, "Dispatched summary digest to Slack channel", Toast.LENGTH_SHORT).show() },
                                            colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                                            shape = RoundedCornerShape(8.dp),
                                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                                            modifier = Modifier.weight(1f).height(38.dp)
                                        ) {
                                            Icon(Icons.Default.Send, contentDescription = null, modifier = Modifier.size(14.dp))
                                            Spacer(modifier = Modifier.width(4.dp))
                                            Text("Slack Digest", fontSize = 11.sp, maxLines = 1)
                                        }
                                        Button(
                                            onClick = { Toast.makeText(context, "Dispatched knowledge brief to Notion Workspace", Toast.LENGTH_SHORT).show() },
                                            colors = ButtonDefaults.buttonColors(containerColor = SurfaceCard),
                                            shape = RoundedCornerShape(8.dp),
                                            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 8.dp),
                                            modifier = Modifier.weight(1f).height(38.dp)
                                        ) {
                                            Icon(Icons.Default.CloudUpload, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(14.dp))
                                            Spacer(modifier = Modifier.width(4.dp))
                                            Text("Notion Wiki", fontSize = 11.sp, color = TextPrimary, maxLines = 1)
                                        }
                                    }
                                }
                            }

                            Spacer(modifier = Modifier.height(16.dp))

                            // Markdown content
                            Card(
                                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                                shape = RoundedCornerShape(16.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text(
                                    text = synthesisText,
                                    color = TextPrimary,
                                    fontSize = 13.sp,
                                    lineHeight = 22.sp,
                                    modifier = Modifier.padding(18.dp)
                                )
                            }
                        }
                    }

                    SynthesisTab.CONFLICTS -> {
                        if (conflicts.isEmpty()) {
                            Box(
                                modifier = Modifier.fillMaxSize().padding(24.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    Icon(Icons.Default.CheckCircle, contentDescription = null, tint = EmeraldSuccess, modifier = Modifier.size(56.dp))
                                    Spacer(modifier = Modifier.height(12.dp))
                                    Text("Zero Direct Contradictions Detected", fontWeight = FontWeight.Bold, color = TextPrimary)
                                    Spacer(modifier = Modifier.height(6.dp))
                                    Text("All extracted directives and architectural plans align across your sessions.", fontSize = 12.sp, color = TextSecondary)
                                }
                            }
                        } else {
                            LazyColumn(
                                contentPadding = PaddingValues(16.dp),
                                verticalArrangement = Arrangement.spacedBy(14.dp),
                                modifier = Modifier.fillMaxSize()
                            ) {
                                item {
                                    Text(
                                        "Potential Contradictions & Changing Requirements:",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = AmberWarning,
                                        fontWeight = FontWeight.Bold
                                    )
                                }

                                items(conflicts, key = { it.id }) { conflict ->
                                    Card(
                                        colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                                        border = androidx.compose.foundation.BorderStroke(1.dp, AmberWarning.copy(alpha = 0.5f)),
                                        shape = RoundedCornerShape(14.dp),
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Column(modifier = Modifier.padding(16.dp)) {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                Icon(Icons.Default.Warning, contentDescription = null, tint = AmberWarning, modifier = Modifier.size(18.dp))
                                                Spacer(modifier = Modifier.width(8.dp))
                                                Text(conflict.topic, fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 14.sp)
                                            }

                                            Spacer(modifier = Modifier.height(10.dp))
                                            Text(conflict.description, color = TextSecondary, fontSize = 13.sp, lineHeight = 20.sp)

                                            Spacer(modifier = Modifier.height(12.dp))
                                            HorizontalDivider(color = SurfaceBorder)
                                            Spacer(modifier = Modifier.height(10.dp))

                                            Text("Resolution Suggestion:", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = IndigoLight)
                                            Text(conflict.resolutionSuggestion, fontSize = 12.sp, color = TextPrimary)

                                            Spacer(modifier = Modifier.height(12.dp))

                                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                                OutlinedButton(
                                                    onClick = { onNavigateToSession(conflict.sessionAId) },
                                                    shape = RoundedCornerShape(8.dp),
                                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text("View: ${conflict.sessionATitle.take(14)}...", fontSize = 11.sp, color = IndigoLight)
                                                }
                                                OutlinedButton(
                                                    onClick = { onNavigateToSession(conflict.sessionBId) },
                                                    shape = RoundedCornerShape(8.dp),
                                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
                                                    modifier = Modifier.weight(1f)
                                                ) {
                                                    Text("View: ${conflict.sessionBTitle.take(14)}...", fontSize = 11.sp, color = IndigoLight)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
