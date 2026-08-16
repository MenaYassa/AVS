package com.example.ui.graph

import android.app.Application
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
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
import com.example.data.model.*
import com.example.data.repository.KnowledgeRepository
import com.example.ui.components.ConfidenceBadge
import com.example.ui.components.KnowledgeGraphCanvas
import com.example.ui.theme.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.util.UUID

data class GlobalGraphUiState(
    val entities: List<GraphEntity> = emptyList(),
    val relationships: List<GraphRelation> = emptyList(),
    val selectedEntityType: EntityType? = null,
    val searchQuery: String = "",
    val selectedEntity: GraphEntity? = null,
    val sessionsWithSelectedEntity: List<Session> = emptyList(),
    val connectedRelations: List<GraphRelation> = emptyList()
)

class GlobalGraphViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _selectedEntityType = MutableStateFlow<EntityType?>(null)
    private val _searchQuery = MutableStateFlow("")
    private val _selectedEntity = MutableStateFlow<GraphEntity?>(null)

    val uiState: StateFlow<GlobalGraphUiState> = combine(
        repository.allSessions,
        _selectedEntityType,
        _searchQuery,
        _selectedEntity
    ) { sessions, filterType, query, selectedEntity ->
        val allEntitiesMap = mutableMapOf<String, GraphEntity>()
        val allRelations = mutableListOf<GraphRelation>()

        sessions.forEach { s ->
            s.entities.forEach { e ->
                allEntitiesMap[e.id] = e
            }
            allRelations.addAll(s.relationships)
        }

        var filteredEntities = allEntitiesMap.values.toList()

        if (filterType != null) {
            filteredEntities = filteredEntities.filter { it.type == filterType }
        }

        if (query.isNotBlank()) {
            filteredEntities = filteredEntities.filter { it.name.contains(query, ignoreCase = true) }
        }

        val sessionsWithEntity = if (selectedEntity != null) {
            sessions.filter { s -> s.entities.any { it.name.equals(selectedEntity.name, ignoreCase = true) } }
        } else {
            emptyList()
        }

        val connectedRelations = if (selectedEntity != null) {
            allRelations.filter { it.sourceId == selectedEntity.id || it.targetId == selectedEntity.id }
        } else {
            emptyList()
        }

        GlobalGraphUiState(
            entities = filteredEntities,
            relationships = allRelations.distinctBy { "${it.sourceId}_${it.targetId}_${it.type.name}" },
            selectedEntityType = filterType,
            searchQuery = query,
            selectedEntity = selectedEntity,
            sessionsWithSelectedEntity = sessionsWithEntity,
            connectedRelations = connectedRelations
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = GlobalGraphUiState()
    )

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
    }

    fun selectEntityType(type: EntityType?) {
        _selectedEntityType.value = if (_selectedEntityType.value == type) null else type
    }

    fun selectEntity(entity: GraphEntity?) {
        _selectedEntity.value = entity
    }

    fun addManualEntity(name: String, type: EntityType, targetSessionId: String?) {
        viewModelScope.launch {
            val entity = GraphEntity(
                id = "ent_${UUID.randomUUID().toString().take(8)}",
                name = name,
                type = type,
                confidence = 1.0,
                mentions = 1
            )
            val sessionList = repository.getAllSessionsList()
            val target = if (targetSessionId != null) {
                sessionList.find { it.id == targetSessionId }
            } else {
                sessionList.firstOrNull()
            }
            if (target != null) {
                repository.addEntityToSession(target.id, entity)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlobalGraphScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: GlobalGraphViewModel = viewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    var showAddEntityDialog by remember { mutableStateOf(false) }
    var newEntityName by remember { mutableStateOf("") }
    var newEntityType by remember { mutableStateOf(EntityType.CONCEPT) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("Global Knowledge Graph", fontWeight = FontWeight.Bold, color = TextPrimary)
                        Text(
                            text = "${uiState.entities.size} Entities • ${uiState.relationships.size} Connections",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                            fontSize = 11.sp
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("graph_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    IconButton(onClick = { showAddEntityDialog = true }) {
                        Icon(Icons.Default.AddCircleOutline, contentDescription = "Add Entity", tint = IndigoLight)
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
            // Search field
            OutlinedTextField(
                value = uiState.searchQuery,
                onValueChange = { viewModel.setSearchQuery(it) },
                placeholder = { Text("Search entities (e.g. Kotlin, Gemini, Alex)...", color = TextMuted, fontSize = 13.sp) },
                leadingIcon = { Icon(Icons.Default.Search, contentDescription = null, tint = TextMuted, modifier = Modifier.size(18.dp)) },
                trailingIcon = {
                    if (uiState.searchQuery.isNotEmpty()) {
                        IconButton(onClick = { viewModel.setSearchQuery("") }) {
                            Icon(Icons.Default.Clear, contentDescription = "Clear", tint = TextMuted, modifier = Modifier.size(16.dp))
                        }
                    }
                },
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
                    .padding(horizontal = 16.dp, vertical = 6.dp)
            )

            // Filter Pills
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .background(DeepSlate)
                    .padding(horizontal = 16.dp, vertical = 4.dp)
            ) {
                listOf(
                    EntityType.PROJECT,
                    EntityType.PERSON,
                    EntityType.TOOL,
                    EntityType.CONCEPT,
                    EntityType.ORGANIZATION
                ).forEach { type ->
                    FilterChip(
                        selected = uiState.selectedEntityType == type,
                        onClick = { viewModel.selectEntityType(type) },
                        label = { Text(type.label, fontSize = 12.sp) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = IndigoPrimary,
                            selectedLabelColor = Color.White,
                            containerColor = SurfaceDark,
                            labelColor = TextSecondary
                        ),
                        modifier = Modifier.testTag("graph_filter_${type.wireName}")
                    )
                }
            }

            Box(modifier = Modifier.weight(1f)) {
                KnowledgeGraphCanvas(
                    entities = uiState.entities,
                    relationships = uiState.relationships,
                    selectedEntity = uiState.selectedEntity,
                    onSelectEntity = { viewModel.selectEntity(it) },
                    modifier = Modifier.fillMaxSize()
                )
            }

            // Entity Detail Sheet
            if (uiState.selectedEntity != null) {
                val entity = uiState.selectedEntity!!
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    shape = RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, IndigoLight.copy(alpha = 0.5f)),
                    modifier = Modifier.fillMaxWidth().testTag("global_entity_card")
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column {
                                Text(
                                    text = entity.name,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.Bold,
                                    color = TextPrimary
                                )
                                Text(
                                    text = "Entity Type: ${entity.type.label}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary
                                )
                            }
                            ConfidenceBadge(entity.confidence)
                        }

                        if (uiState.connectedRelations.isNotEmpty()) {
                            Spacer(modifier = Modifier.height(10.dp))
                            Text(
                                text = "Graph Connections (${uiState.connectedRelations.size}):",
                                style = MaterialTheme.typography.labelSmall,
                                color = IndigoLight,
                                fontWeight = FontWeight.Bold
                            )
                            Spacer(modifier = Modifier.height(4.dp))
                            LazyColumn(modifier = Modifier.heightIn(max = 70.dp)) {
                                items(uiState.connectedRelations) { rel ->
                                    val otherId = if (rel.sourceId == entity.id) rel.targetId else rel.sourceId
                                    val otherEntity = uiState.entities.find { it.id == otherId }
                                    Text(
                                        text = "• ${rel.type.label} ➔ ${otherEntity?.name ?: otherId}",
                                        fontSize = 12.sp,
                                        color = TextPrimary
                                    )
                                }
                            }
                        }

                        if (uiState.sessionsWithSelectedEntity.isNotEmpty()) {
                            Spacer(modifier = Modifier.height(10.dp))
                            Text(
                                text = "Appears in ${uiState.sessionsWithSelectedEntity.size} session(s):",
                                style = MaterialTheme.typography.labelSmall,
                                color = TextSecondary,
                                fontWeight = FontWeight.SemiBold
                            )
                            Spacer(modifier = Modifier.height(6.dp))
                            LazyColumn(modifier = Modifier.heightIn(max = 100.dp)) {
                                items(uiState.sessionsWithSelectedEntity) { s ->
                                    Card(
                                        onClick = { onNavigateToSession(s.id) },
                                        colors = CardDefaults.cardColors(containerColor = SurfaceCard),
                                        shape = RoundedCornerShape(8.dp),
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            modifier = Modifier.padding(8.dp)
                                        ) {
                                            Text(s.title ?: "Session", color = TextPrimary, fontSize = 12.sp, modifier = Modifier.weight(1f))
                                            Icon(Icons.Default.ChevronRight, contentDescription = null, tint = TextMuted, modifier = Modifier.size(16.dp))
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

    if (showAddEntityDialog) {
        AlertDialog(
            onDismissRequest = { showAddEntityDialog = false },
            title = { Text("Add Manual Knowledge Entity", fontWeight = FontWeight.Bold) },
            text = {
                Column {
                    OutlinedTextField(
                        value = newEntityName,
                        onValueChange = { newEntityName = it },
                        label = { Text("Entity Name (e.g. Jetpack Compose)") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth()
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text("Type:", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    ) {
                        listOf(EntityType.PROJECT, EntityType.PERSON, EntityType.TOOL, EntityType.CONCEPT, EntityType.ORGANIZATION).forEach { t ->
                            FilterChip(
                                selected = newEntityType == t,
                                onClick = { newEntityType = t },
                                label = { Text(t.label, fontSize = 11.sp) }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (newEntityName.isNotBlank()) {
                            viewModel.addManualEntity(newEntityName, newEntityType, null)
                            newEntityName = ""
                            showAddEntityDialog = false
                        }
                    }
                ) {
                    Text("Add Entity")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddEntityDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}
