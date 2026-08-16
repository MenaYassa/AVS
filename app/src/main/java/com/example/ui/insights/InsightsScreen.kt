package com.example.ui.insights

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.model.*
import com.example.data.repository.KnowledgeRepository
import com.example.ui.components.ConfidenceBadge
import com.example.ui.components.ItemTypeBadge
import com.example.ui.components.PriorityBadge
import com.example.ui.theme.*
import kotlinx.coroutines.flow.*

data class InsightsUiState(
    val totalSessions: Int = 0,
    val openTasks: List<Pair<String, Item>> = emptyList(), // Pair of sessionTitle to Item
    val topPeople: List<Pair<String, Int>> = emptyList(), // Name to occurrence count
    val topProjects: List<Pair<String, Int>> = emptyList(),
    val keyDecisions: List<Pair<String, Item>> = emptyList()
)

class InsightsViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    val uiState: StateFlow<InsightsUiState> = repository.allSessions.map { sessions ->
        val tasks = mutableListOf<Pair<String, Item>>()
        val decisions = mutableListOf<Pair<String, Item>>()
        val peopleCounts = mutableMapOf<String, Int>()
        val projectCounts = mutableMapOf<String, Int>()

        sessions.forEach { session ->
            val sessionName = session.title ?: "Session"
            session.topics.forEach { topic ->
                topic.items.forEach { item ->
                    if ((item.type == ItemType.TASK || item.type == ItemType.ACTION_ITEM) && !item.completed) {
                        tasks.add(Pair(sessionName, item))
                    } else if (item.type == ItemType.DECISION) {
                        decisions.add(Pair(sessionName, item))
                    }
                }
            }

            session.entities.forEach { entity ->
                if (entity.type == EntityType.PERSON) {
                    peopleCounts[entity.name] = (peopleCounts[entity.name] ?: 0) + 1
                } else if (entity.type == EntityType.PROJECT || entity.type == EntityType.TOOL) {
                    projectCounts[entity.name] = (projectCounts[entity.name] ?: 0) + 1
                }
            }
        }

        InsightsUiState(
            totalSessions = sessions.size,
            openTasks = tasks,
            topPeople = peopleCounts.toList().sortedByDescending { it.second },
            topProjects = projectCounts.toList().sortedByDescending { it.second },
            keyDecisions = decisions
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = InsightsUiState()
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InsightsScreen(
    onNavigateBack: () -> Unit,
    viewModel: InsightsViewModel = viewModel()
) {
    val uiState by viewModel.uiState.collectAsState()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("Cross-Session Intelligence", fontWeight = FontWeight.Bold, color = TextPrimary)
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("insights_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = DeepSlate)
            )
        },
        containerColor = DeepSlate
    ) { padding ->
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            // Header Stats Banner
            item {
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(20.dp),
                        horizontalArrangement = Arrangement.SpaceAround,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("${uiState.totalSessions}", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = IndigoLight)
                            Text("Sessions", fontSize = 12.sp, color = TextSecondary)
                        }
                        Box(modifier = Modifier.width(1.dp).height(36.dp).background(SurfaceBorder))
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("${uiState.openTasks.size}", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = AmberWarning)
                            Text("Open Tasks", fontSize = 12.sp, color = TextSecondary)
                        }
                        Box(modifier = Modifier.width(1.dp).height(36.dp).background(SurfaceBorder))
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Text("${uiState.keyDecisions.size}", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = EmeraldSuccess)
                            Text("Decisions", fontSize = 12.sp, color = TextSecondary)
                        }
                    }
                }
            }

            // Top Recurring Collaborators
            if (uiState.topPeople.isNotEmpty()) {
                item {
                    Text(
                        text = "Frequent Collaborators & Mentions",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary
                    )
                }

                item {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        uiState.topPeople.take(4).forEach { (person, count) ->
                            Card(
                                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                                shape = RoundedCornerShape(14.dp),
                                modifier = Modifier.weight(1f)
                            ) {
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    modifier = Modifier.padding(12.dp).fillMaxWidth()
                                ) {
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier
                                            .size(36.dp)
                                            .clip(CircleShape)
                                            .background(IndigoPrimary.copy(alpha = 0.2f))
                                    ) {
                                        Text(person.take(1), fontWeight = FontWeight.Bold, color = IndigoLight)
                                    }
                                    Spacer(modifier = Modifier.height(6.dp))
                                    Text(person, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = TextPrimary, maxLines = 1)
                                    Text("$count sessions", fontSize = 10.sp, color = TextSecondary)
                                }
                            }
                        }
                    }
                }
            }

            // Aggregated Open Tasks
            item {
                Text(
                    text = "Aggregated Open Deliverables",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
            }

            if (uiState.openTasks.isEmpty()) {
                item {
                    Text("All tasks across all sessions completed!", color = TextMuted, fontSize = 13.sp)
                }
            } else {
                items(uiState.openTasks) { (sessionName, task) ->
                    Card(
                        colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                        border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.6f)),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(12.dp)
                        ) {
                            Icon(Icons.Default.CheckCircleOutline, contentDescription = null, tint = AmberWarning, modifier = Modifier.size(20.dp))
                            Spacer(modifier = Modifier.width(10.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(task.title, fontWeight = FontWeight.SemiBold, color = TextPrimary, fontSize = 13.sp)
                                Text("From: $sessionName", fontSize = 11.sp, color = TextSecondary)
                            }
                            Spacer(modifier = Modifier.width(8.dp))
                            PriorityBadge(task.priority)
                        }
                    }
                }
            }

            // Key Strategic Decisions
            item {
                Text(
                    text = "Cross-Session Strategic Decisions",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
            }

            items(uiState.keyDecisions) { (sessionName, decision) ->
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = androidx.compose.foundation.BorderStroke(1.dp, EmeraldSuccess.copy(alpha = 0.3f)),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(12.dp)
                    ) {
                        Icon(Icons.Default.Gavel, contentDescription = null, tint = EmeraldSuccess, modifier = Modifier.size(20.dp))
                        Spacer(modifier = Modifier.width(10.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(decision.title, fontWeight = FontWeight.SemiBold, color = TextPrimary, fontSize = 13.sp)
                            Text("Session: $sessionName", fontSize = 11.sp, color = TextSecondary)
                        }
                    }
                }
            }
        }
    }
}
