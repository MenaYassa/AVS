package com.example.ui.detail

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.*
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.material3.TabRowDefaults.tabIndicatorOffset
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.model.*
import com.example.ui.components.*
import com.example.ui.theme.*

class SessionDetailViewModelFactory(
    private val application: Application,
    private val sessionId: String
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        return SessionDetailViewModel(application, sessionId) as T
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionDetailScreen(
    sessionId: String,
    onNavigateBack: () -> Unit,
    onNavigateToDraft: (String, String) -> Unit
) {
    val context = LocalContext.current
    val app = context.applicationContext as Application
    val viewModel: SessionDetailViewModel = viewModel(
        key = sessionId,
        factory = SessionDetailViewModelFactory(app, sessionId)
    )

    val uiState by viewModel.uiState.collectAsState()
    val session = uiState.session

    var showAddItemDialogForTopicId by remember { mutableStateOf<String?>(null) }
    var newItemTitle by remember { mutableStateOf("") }
    var newItemType by remember { mutableStateOf(ItemType.TASK) }
    var newItemPriority by remember { mutableStateOf(Priority.MEDIUM) }

    // Item Edit State
    var selectedItemForEdit by remember { mutableStateOf<Triple<String, String, Item>?>(null) } // topicId, topicTitle, Item
    var showExportSheet by remember { mutableStateOf(false) }

    if (session == null) {
        Box(modifier = Modifier.fillMaxSize().background(DeepSlate), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = IndigoLight)
        }
        return
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = session.title ?: "Session Details",
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("detail_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    IconButton(
                        onClick = { showExportSheet = true },
                        modifier = Modifier.testTag("detail_export_btn")
                    ) {
                        Icon(
                            imageVector = Icons.Default.Share,
                            contentDescription = "Export Session",
                            tint = IndigoLight
                        )
                    }
                    IconButton(
                        onClick = { viewModel.toggleFavorite() },
                        modifier = Modifier.testTag("detail_favorite_btn")
                    ) {
                        Icon(
                            imageVector = if (session.favorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                            contentDescription = "Favorite",
                            tint = if (session.favorite) AmberWarning else TextMuted
                        )
                    }
                    IconButton(
                        onClick = { viewModel.togglePin() },
                        modifier = Modifier.testTag("detail_pin_btn")
                    ) {
                        Icon(
                            imageVector = if (session.pinned) Icons.Filled.PushPin else Icons.Outlined.PushPin,
                            contentDescription = "Pin",
                            tint = if (session.pinned) IndigoLight else TextMuted
                        )
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
            // Audio Player Bar (only for voice sessions with actual audio recording)
            if (!session.audioPath.isNullOrBlank() && session.durationSec != null && session.durationSec > 0) {
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    shape = RoundedCornerShape(0.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            IconButton(
                                onClick = { viewModel.togglePlayPause() },
                                colors = IconButtonDefaults.iconButtonColors(containerColor = IndigoPrimary),
                                modifier = Modifier.size(38.dp).testTag("play_audio_btn")
                            ) {
                                Icon(
                                    imageVector = if (uiState.isPlayingAudio) Icons.Default.Pause else Icons.Default.PlayArrow,
                                    contentDescription = "Play Audio",
                                    tint = Color.White,
                                    modifier = Modifier.size(20.dp)
                                )
                            }
                            Spacer(modifier = Modifier.width(12.dp))

                            Box(modifier = Modifier.weight(1f)) {
                                AudioWaveform(
                                    isPlaying = uiState.isPlayingAudio,
                                    progress = uiState.audioProgress,
                                    activeColor = IndigoLight,
                                    inactiveColor = SurfaceBorder,
                                    barCount = 28,
                                    modifier = Modifier.height(30.dp)
                                )
                            }

                            Spacer(modifier = Modifier.width(12.dp))

                            val totalSec = session.durationSec.toInt()
                            val curSec = (totalSec * uiState.audioProgress).toInt()
                            Text(
                                text = String.format("%02d:%02d / %02d:%02d", curSec / 60, curSec % 60, totalSec / 60, totalSec % 60),
                                fontSize = 11.sp,
                                color = TextMuted,
                                fontWeight = FontWeight.Medium
                            )

                            Spacer(modifier = Modifier.width(8.dp))

                            TextButton(
                                onClick = {
                                    val nextSpeed = when (uiState.playbackSpeed) {
                                        1.0f -> 1.25f
                                        1.25f -> 1.5f
                                        1.5f -> 2.0f
                                        else -> 1.0f
                                    }
                                    viewModel.setPlaybackSpeed(nextSpeed)
                                },
                                contentPadding = PaddingValues(horizontal = 4.dp, vertical = 2.dp)
                            ) {
                                Text("${uiState.playbackSpeed}x", color = IndigoLight, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            } else {
                // Non-audio session header bar (Documents, OCR Scans, Notes)
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    shape = RoundedCornerShape(0.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 10.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            val isCamera = session.tags.any { it.contains("Camera", true) || it.contains("Image", true) || it.contains("Whiteboard", true) }
                            val icon = if (isCamera) Icons.Default.CameraAlt else Icons.Default.Description
                            Icon(
                                imageVector = icon,
                                contentDescription = null,
                                tint = IndigoLight,
                                modifier = Modifier.size(18.dp)
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = if (isCamera) "Visual OCR Extraction" else "Synthesized Document",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = "${session.wordCount} words",
                                fontSize = 11.sp,
                                color = TextSecondary
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Surface(
                                color = EmeraldContainer.copy(alpha = 0.4f),
                                shape = RoundedCornerShape(6.dp)
                            ) {
                                Text(
                                    text = "${(((session.extractionConfidence ?: 0.9)) * 100).toInt()}% Conf",
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = EmeraldSuccess,
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                )
                            }
                        }
                    }
                }
            }

            // Scrollable Tab Navigation Bar
            ScrollableTabRow(
                selectedTabIndex = uiState.selectedTab.ordinal,
                containerColor = SurfaceDark,
                contentColor = TextPrimary,
                edgePadding = 16.dp,
                indicator = { tabPositions ->
                    if (uiState.selectedTab.ordinal < tabPositions.size) {
                        TabRowDefaults.SecondaryIndicator(
                            modifier = Modifier.tabIndicatorOffset(tabPositions[uiState.selectedTab.ordinal]),
                            color = IndigoLight,
                            height = 3.dp
                        )
                    }
                },
                divider = { HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f)) }
            ) {
                DetailTab.entries.forEach { tab ->
                    Tab(
                        selected = uiState.selectedTab == tab,
                        onClick = { viewModel.selectTab(tab) },
                        text = {
                            Text(
                                text = tab.label,
                                fontWeight = if (uiState.selectedTab == tab) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 13.sp,
                                color = if (uiState.selectedTab == tab) IndigoLight else TextSecondary
                            )
                        },
                        modifier = Modifier.testTag("tab_${tab.name.lowercase()}")
                    )
                }
            }

            // Content Area based on Tab
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .weight(1f)
            ) {
                when (uiState.selectedTab) {
                    DetailTab.TOPICS -> TopicsTabContent(
                        session = session,
                        onToggleItem = { topicId, itemId -> viewModel.toggleItemCompletion(topicId, itemId) },
                        onItemClick = { topicId, topicTitle, item ->
                            selectedItemForEdit = Triple(topicId, topicTitle, item)
                        },
                        onAddItemClick = { topicId -> showAddItemDialogForTopicId = topicId }
                    )
                    DetailTab.GRAPH -> GraphTabContent(
                        session = session,
                        selectedEntity = uiState.selectedEntity,
                        onSelectEntity = { viewModel.selectEntity(it) }
                    )
                    DetailTab.TRANSCRIPT -> TranscriptTabContent(
                        session = session,
                        onSeekToSec = { sec -> viewModel.seekToSecond(sec) },
                        onApplyPersona = { persona -> viewModel.applyPersona(persona) }
                    )
                    DetailTab.CHAT -> ChatTabContent(
                        session = session,
                        messages = uiState.chatMessages,
                        isSending = uiState.isSendingChat,
                        onSendMessage = { query, isThinking, isFast ->
                            viewModel.sendChatMessage(query, isThinking, isFast)
                        }
                    )
                    DetailTab.COMMANDS -> CommandsTabContent(
                        session = session,
                        drafts = uiState.drafts,
                        isRunning = uiState.isRunningCommand,
                        onRunCommand = { cmd ->
                            viewModel.runCommand(cmd) { draftId ->
                                onNavigateToDraft(session.id, draftId)
                            }
                        },
                        onOpenDraft = { draftId -> onNavigateToDraft(session.id, draftId) }
                    )
                    DetailTab.HISTORY -> HistoryTabContent(
                        versions = uiState.versions,
                        onRestore = { viewModel.restoreVersion(it) }
                    )
                }
            }
        }
    }

    // Item Action & Editor Bottom Sheet
    selectedItemForEdit?.let { (topicId, topicTitle, item) ->
        ItemEditorBottomSheet(
            topicTitle = topicTitle,
            item = item,
            onDismiss = { selectedItemForEdit = null },
            onSave = { updatedTitle, updatedDesc, updatedType, updatedPriority, isCompleted ->
                viewModel.updateItem(
                    topicId = topicId,
                    itemId = item.id,
                    newTitle = updatedTitle,
                    newDescription = updatedDesc,
                    newType = updatedType,
                    newPriority = updatedPriority,
                    isCompleted = isCompleted
                )
                selectedItemForEdit = null
            },
            onDelete = {
                viewModel.deleteItem(topicId, item.id)
                selectedItemForEdit = null
            }
        )
    }

    if (showExportSheet) {
        ExportBottomSheet(
            session = session,
            onDismiss = { showExportSheet = false },
            onGetExportContent = { format -> viewModel.getExportContent(format) }
        )
    }

    // Add Item Dialog
    if (showAddItemDialogForTopicId != null) {
        val topicId = showAddItemDialogForTopicId!!
        AlertDialog(
            onDismissRequest = { showAddItemDialogForTopicId = null },
            title = { Text("Add New Item / Task", fontWeight = FontWeight.Bold) },
            text = {
                Column {
                    OutlinedTextField(
                        value = newItemTitle,
                        onValueChange = { newItemTitle = it },
                        label = { Text("Item Title") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth().testTag("add_item_title_input")
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text("Type:", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                    ) {
                        listOf(ItemType.TASK, ItemType.ACTION_ITEM, ItemType.DECISION, ItemType.QUESTION, ItemType.IDEA).forEach { type ->
                            FilterChip(
                                selected = newItemType == type,
                                onClick = { newItemType = type },
                                label = { Text(type.label, fontSize = 11.sp) }
                            )
                        }
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                    Text("Priority:", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        listOf(Priority.LOW, Priority.MEDIUM, Priority.HIGH).forEach { p ->
                            FilterChip(
                                selected = newItemPriority == p,
                                onClick = { newItemPriority = p },
                                label = { Text(p.label, fontSize = 11.sp) }
                            )
                        }
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (newItemTitle.isNotBlank()) {
                            viewModel.addNewItemToTopic(topicId, newItemTitle, newItemType, newItemPriority)
                            newItemTitle = ""
                            showAddItemDialogForTopicId = null
                        }
                    },
                    modifier = Modifier.testTag("confirm_add_item_btn")
                ) {
                    Text("Add")
                }
            },
            dismissButton = {
                TextButton(onClick = { showAddItemDialogForTopicId = null }) {
                    Text("Cancel")
                }
            }
        )
    }
}

// ----------------- SUB-TABS -----------------

@Composable
private fun TopicsTabContent(
    session: Session,
    onToggleItem: (String, String) -> Unit,
    onItemClick: (String, String, Item) -> Unit,
    onAddItemClick: (String) -> Unit
) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        items(session.topics, key = { it.id }) { topic ->
            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.6f)),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth().testTag("topic_card_${topic.id}")
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = topic.title,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                            if (topic.description.isNotBlank()) {
                                Text(
                                    text = topic.description,
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary,
                                    fontSize = 12.sp
                                )
                            }
                        }
                        ConfidenceBadge(topic.confidence)
                    }

                    Spacer(modifier = Modifier.height(12.dp))

                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        topic.items.forEach { item ->
                            val isTask = item.type == ItemType.TASK || item.type == ItemType.ACTION_ITEM
                            Card(
                                colors = CardDefaults.cardColors(containerColor = SurfaceCard.copy(alpha = 0.6f)),
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { onItemClick(topic.id, topic.title, item) }
                                    .testTag("item_row_${item.id}")
                            ) {
                                Row(
                                    verticalAlignment = Alignment.Top,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(10.dp)
                                    ) {
                                    if (isTask) {
                                        Checkbox(
                                            checked = item.completed,
                                            onCheckedChange = { onToggleItem(topic.id, item.id) },
                                            colors = CheckboxDefaults.colors(
                                                checkedColor = EmeraldSuccess,
                                                uncheckedColor = TextSecondary
                                            ),
                                            modifier = Modifier
                                                .size(24.dp)
                                                .padding(top = 1.dp)
                                                .testTag("checkbox_${item.id}")
                                        )
                                        Spacer(modifier = Modifier.width(10.dp))
                                    }

                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = item.title,
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = if (item.completed) TextMuted else TextPrimary,
                                            textDecoration = if (item.completed) TextDecoration.LineThrough else TextDecoration.None,
                                            fontWeight = FontWeight.SemiBold,
                                            lineHeight = 20.sp
                                        )
                                        if (item.description.isNotBlank()) {
                                            Spacer(modifier = Modifier.height(4.dp))
                                            Text(
                                                text = item.description,
                                                style = MaterialTheme.typography.bodySmall,
                                                color = TextSecondary,
                                                fontSize = 12.sp,
                                                lineHeight = 16.sp
                                            )
                                        }

                                        Spacer(modifier = Modifier.height(8.dp))

                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Row(
                                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                ItemTypeBadge(item.type)
                                                PriorityBadge(item.priority)
                                            }

                                            IconButton(
                                                onClick = { onItemClick(topic.id, topic.title, item) },
                                                modifier = Modifier.size(24.dp).testTag("edit_item_btn_${item.id}")
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.MoreVert,
                                                    contentDescription = "Edit Item",
                                                    tint = TextMuted,
                                                    modifier = Modifier.size(16.dp)
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Spacer(modifier = Modifier.height(10.dp))

                    TextButton(
                        onClick = { onAddItemClick(topic.id) },
                        modifier = Modifier.align(Alignment.End).testTag("add_item_to_topic_${topic.id}")
                    ) {
                        Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp), tint = IndigoLight)
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("Add Item", color = IndigoLight, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ItemEditorBottomSheet(
    topicTitle: String,
    item: Item,
    onDismiss: () -> Unit,
    onSave: (title: String, description: String, type: ItemType, priority: Priority, isCompleted: Boolean) -> Unit,
    onDelete: () -> Unit
) {
    val context = LocalContext.current
    var editTitle by remember { mutableStateOf(item.title) }
    var editDesc by remember { mutableStateOf(item.description) }
    var editType by remember { mutableStateOf(item.type) }
    var editPriority by remember { mutableStateOf(item.priority ?: Priority.MEDIUM) }
    var editCompleted by remember { mutableStateOf(item.completed) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SurfaceDark,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SurfaceBorder) }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState())
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    Text(
                        text = "Edit Item / Takeaway",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary
                    )
                    Text(
                        text = "Under topic: $topicTitle",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                        fontSize = 11.sp
                    )
                }

                IconButton(
                    onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val copyText = buildString {
                            appendLine(editTitle)
                            if (editDesc.isNotBlank()) appendLine(editDesc)
                            appendLine("[Type: ${editType.label} • Priority: ${editPriority.label}]")
                        }
                        clipboard.setPrimaryClip(ClipData.newPlainText("Item", copyText))
                        Toast.makeText(context, "Item copied to clipboard", Toast.LENGTH_SHORT).show()
                    },
                    modifier = Modifier.testTag("copy_item_clipboard_btn")
                ) {
                    Icon(
                        imageVector = Icons.Default.ContentCopy,
                        contentDescription = "Copy Item Text",
                        tint = TextSecondary,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Title Field
            OutlinedTextField(
                value = editTitle,
                onValueChange = { editTitle = it },
                label = { Text("Title / Summary") },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = SurfaceCard,
                    unfocusedContainerColor = SurfaceCard,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().testTag("edit_item_title_input")
            )

            Spacer(modifier = Modifier.height(12.dp))

            // Description / Details Field
            OutlinedTextField(
                value = editDesc,
                onValueChange = { editDesc = it },
                label = { Text("Details / Context (Optional)") },
                minLines = 2,
                maxLines = 4,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = SurfaceCard,
                    unfocusedContainerColor = SurfaceCard,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder
                ),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().testTag("edit_item_desc_input")
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Type Selector
            Text("Classification Type:", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(modifier = Modifier.height(6.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
            ) {
                ItemType.entries.forEach { type ->
                    FilterChip(
                        selected = editType == type,
                        onClick = { editType = type },
                        label = { Text(type.label, fontSize = 12.sp, fontWeight = FontWeight.Medium) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = IndigoPrimary,
                            selectedLabelColor = Color.White,
                            containerColor = SurfaceCard,
                            labelColor = TextSecondary
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.testTag("item_type_chip_${type.name.lowercase()}")
                    )
                }
            }

            Spacer(modifier = Modifier.height(14.dp))

            // Priority Selector
            Text("Priority:", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(modifier = Modifier.height(6.dp))
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Priority.entries.forEach { p ->
                    FilterChip(
                        selected = editPriority == p,
                        onClick = { editPriority = p },
                        label = { Text(p.label, fontSize = 12.sp, fontWeight = FontWeight.Medium) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = when (p) {
                                Priority.HIGH -> RoseError
                                Priority.MEDIUM -> AmberWarning
                                Priority.LOW -> IndigoPrimary
                            },
                            selectedLabelColor = Color.White,
                            containerColor = SurfaceCard,
                            labelColor = TextSecondary
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.testTag("item_priority_chip_${p.name.lowercase()}")
                    )
                }
            }

            Spacer(modifier = Modifier.height(14.dp))

            // Completed Checkbox Row (for tasks or general items)
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(SurfaceCard)
                    .clickable { editCompleted = !editCompleted }
                    .padding(horizontal = 14.dp, vertical = 8.dp)
            ) {
                Checkbox(
                    checked = editCompleted,
                    onCheckedChange = { editCompleted = it },
                    colors = CheckboxDefaults.colors(
                        checkedColor = EmeraldSuccess,
                        uncheckedColor = TextSecondary
                    )
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "Marked as Resolved / Completed",
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextPrimary,
                    fontWeight = FontWeight.Medium
                )
            }

            Spacer(modifier = Modifier.height(20.dp))

            // Actions row: Delete Button & Save Button
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp)
            ) {
                OutlinedButton(
                    onClick = onDelete,
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = RoseError),
                    border = androidx.compose.foundation.BorderStroke(1.dp, RoseError.copy(alpha = 0.6f)),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f).testTag("delete_item_btn")
                ) {
                    Icon(Icons.Default.Delete, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Delete")
                }

                Button(
                    onClick = {
                        if (editTitle.isNotBlank()) {
                            onSave(editTitle, editDesc, editType, editPriority, editCompleted)
                        }
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1.5f).testTag("save_item_changes_btn")
                ) {
                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Save Changes", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun GraphTabContent(
    session: Session,
    selectedEntity: GraphEntity?,
    onSelectEntity: (GraphEntity?) -> Unit
) {
    Column(modifier = Modifier.fillMaxSize()) {
        Box(modifier = Modifier.weight(1f)) {
            KnowledgeGraphCanvas(
                entities = session.entities,
                relationships = session.relationships,
                selectedEntity = selectedEntity,
                onSelectEntity = onSelectEntity,
                modifier = Modifier.fillMaxSize()
            )
        }

        // Entity inspector drawer
        if (selectedEntity != null) {
            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                shape = RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp),
                border = androidx.compose.foundation.BorderStroke(1.dp, IndigoLight.copy(alpha = 0.5f)),
                modifier = Modifier.fillMaxWidth().testTag("entity_inspector_card")
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Hub, contentDescription = null, tint = IndigoLight)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                text = selectedEntity.name,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                        }
                        ConfidenceBadge(selectedEntity.confidence)
                    }

                    Spacer(modifier = Modifier.height(6.dp))
                    Text("Type: ${selectedEntity.type.label}", color = TextSecondary, fontSize = 12.sp)

                    if (selectedEntity.aliases.isNotEmpty()) {
                        Text("Aliases: ${selectedEntity.aliases.joinToString(", ")}", color = TextMuted, fontSize = 11.sp)
                    }

                    val connected = session.relationships.filter {
                        it.sourceId == selectedEntity.id || it.targetId == selectedEntity.id
                    }

                    if (connected.isNotEmpty()) {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text("Relationships (${connected.size}):", fontWeight = FontWeight.SemiBold, color = TextPrimary, fontSize = 12.sp)
                        connected.forEach { rel ->
                            val otherId = if (rel.sourceId == selectedEntity.id) rel.targetId else rel.sourceId
                            val otherName = session.entities.find { it.id == otherId }?.name ?: otherId
                            Text("• ${rel.type.label} → $otherName", color = TextSecondary, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptTabContent(
    session: Session,
    onSeekToSec: (Double) -> Unit,
    onApplyPersona: (PromptPersona) -> Unit
) {
    val context = LocalContext.current
    var showRaw by remember { mutableStateOf(false) }
    var selectedPersona by remember { mutableStateOf(PromptPersona.EXECUTIVE_BRIEF) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState())
    ) {
        // AI Persona Style Re-synthesis Bar
        Card(
            colors = CardDefaults.cardColors(containerColor = SurfaceDark),
            border = androidx.compose.foundation.BorderStroke(1.dp, IndigoPrimary.copy(alpha = 0.4f)),
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(modifier = Modifier.padding(14.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Persona Synthesis Style", fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 13.sp)
                    }
                    Text("1-Tap Re-analyze", color = TextSecondary, fontSize = 10.sp)
                }

                Spacer(modifier = Modifier.height(10.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
                ) {
                    PromptPersona.entries.forEach { persona ->
                        FilterChip(
                            selected = selectedPersona == persona,
                            onClick = {
                                selectedPersona = persona
                                onApplyPersona(persona)
                                Toast.makeText(context, "Applying ${persona.label} persona...", Toast.LENGTH_SHORT).show()
                            },
                            label = { Text(persona.label, fontSize = 11.sp, fontWeight = FontWeight.Medium) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = IndigoPrimary,
                                selectedLabelColor = Color.White,
                                containerColor = SurfaceCard,
                                labelColor = TextSecondary
                            ),
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.testTag("persona_chip_${persona.name.lowercase()}")
                        )
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(14.dp))

        // Executive Summary Card
        Card(
            colors = CardDefaults.cardColors(containerColor = SurfaceDark),
            border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
            shape = RoundedCornerShape(16.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text(
                        text = "Executive Summary",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary
                    )
                    ConfidenceBadge(session.summaryConfidence)
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = session.summary ?: "No summary available.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextPrimary,
                    lineHeight = 22.sp
                )
                Spacer(modifier = Modifier.height(10.dp))
                Row(
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    session.tags.forEach { tag ->
                        TagChip(tag = tag)
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Diarized Speaker Segments (if available)
        if (session.segments.isNotEmpty()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = "Diarized Speaker Segments (${session.segments.size})",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
                Text(
                    text = "Tap timestamp to seek",
                    fontSize = 11.sp,
                    color = IndigoLight
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                session.segments.forEach { segment ->
                    Card(
                        colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                        border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.5f)),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.padding(12.dp)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Surface(
                                        color = when (segment.speaker) {
                                            "Speaker 1" -> IndigoPrimary.copy(alpha = 0.3f)
                                            "Speaker 2" -> VioletAccent.copy(alpha = 0.3f)
                                            else -> TealAccent.copy(alpha = 0.3f)
                                        },
                                        shape = RoundedCornerShape(6.dp)
                                    ) {
                                        Text(
                                            text = segment.speaker,
                                            fontSize = 10.sp,
                                            fontWeight = FontWeight.Bold,
                                            color = when (segment.speaker) {
                                                "Speaker 1" -> IndigoLight
                                                "Speaker 2" -> VioletAccent
                                                else -> TealAccent
                                            },
                                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                        )
                                    }

                                    Spacer(modifier = Modifier.width(8.dp))

                                    // Timestamp seek chip
                                    val startM = (segment.startSec / 60).toInt()
                                    val startS = (segment.startSec % 60).toInt()
                                    Surface(
                                        color = SurfaceCard,
                                        shape = RoundedCornerShape(6.dp),
                                        modifier = Modifier.clickable {
                                            onSeekToSec(segment.startSec)
                                            Toast.makeText(context, "Seeking to ${String.format("%02d:%02d", startM, startS)}", Toast.LENGTH_SHORT).show()
                                        }.testTag("seek_segment_${segment.id}")
                                    ) {
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                        ) {
                                            Icon(Icons.Default.PlayArrow, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(12.dp))
                                            Spacer(modifier = Modifier.width(2.dp))
                                            Text(
                                                text = String.format("%02d:%02d", startM, startS),
                                                fontSize = 10.sp,
                                                fontWeight = FontWeight.Bold,
                                                color = IndigoLight
                                            )
                                        }
                                    }
                                }

                                ConfidenceBadge(segment.confidence)
                            }

                            Spacer(modifier = Modifier.height(6.dp))

                            Text(
                                text = segment.text,
                                style = MaterialTheme.typography.bodySmall,
                                color = TextPrimary,
                                lineHeight = 18.sp
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))
        }

        // Cleaned vs Raw Transcript Full Text
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = if (showRaw) "Raw Spoken Transcript" else "Cleaned & Normalized Transcript",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = TextPrimary
            )

            Row {
                TextButton(onClick = { showRaw = !showRaw }) {
                    Text(if (showRaw) "Show Cleaned" else "Show Raw", color = IndigoLight, fontSize = 12.sp)
                }

                IconButton(onClick = {
                    val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val clip = ClipData.newPlainText("Transcript", if (showRaw) session.originalTranscript else session.cleanedTranscript)
                    clipboard.setPrimaryClip(clip)
                    Toast.makeText(context, "Copied transcript to clipboard", Toast.LENGTH_SHORT).show()
                }) {
                    Icon(Icons.Default.ContentCopy, contentDescription = "Copy", tint = TextSecondary, modifier = Modifier.size(18.dp))
                }
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Card(
            colors = CardDefaults.cardColors(containerColor = SurfaceDark),
            border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.5f)),
            shape = RoundedCornerShape(14.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = (if (showRaw) session.originalTranscript else session.cleanedTranscript) ?: "No transcript available.",
                style = MaterialTheme.typography.bodyMedium,
                color = TextPrimary,
                lineHeight = 24.sp,
                modifier = Modifier.padding(16.dp).testTag("transcript_full_text")
            )
        }

        Spacer(modifier = Modifier.height(24.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ExportBottomSheet(
    session: Session,
    onDismiss: () -> Unit,
    onGetExportContent: (ExportFormat) -> String
) {
    val context = LocalContext.current
    var selectedFormat by remember { mutableStateOf(ExportFormat.OBSIDIAN_MARKDOWN) }
    val formattedContent by remember(selectedFormat) {
        derivedStateOf { onGetExportContent(selectedFormat) }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SurfaceDark,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SurfaceBorder) }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState())
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Share, contentDescription = null, tint = IndigoLight)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Export Knowledge Session", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, color = TextPrimary)
                }
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = TextMuted)
                }
            }

            Spacer(modifier = Modifier.height(14.dp))

            Text("Select Format:", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(modifier = Modifier.height(6.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState())
            ) {
                ExportFormat.entries.forEach { format ->
                    FilterChip(
                        selected = selectedFormat == format,
                        onClick = { selectedFormat = format },
                        label = { Text(format.label, fontSize = 11.sp, fontWeight = FontWeight.Medium) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = IndigoPrimary,
                            selectedLabelColor = Color.White,
                            containerColor = SurfaceCard,
                            labelColor = TextSecondary
                        ),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.testTag("export_chip_${format.name.lowercase()}")
                    )
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            Text("Preview Output:", style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(modifier = Modifier.height(6.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = DeepSlate),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth().heightIn(max = 240.dp)
            ) {
                Text(
                    text = formattedContent,
                    fontSize = 11.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                    color = TextPrimary,
                    modifier = Modifier.padding(12.dp).verticalScroll(rememberScrollState())
                )
            }

            Spacer(modifier = Modifier.height(20.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth().padding(bottom = 24.dp)
            ) {
                OutlinedButton(
                    onClick = {
                        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                        val clip = ClipData.newPlainText(selectedFormat.label, formattedContent)
                        clipboard.setPrimaryClip(clip)
                        Toast.makeText(context, "Copied ${selectedFormat.label} to clipboard!", Toast.LENGTH_SHORT).show()
                    },
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = IndigoLight),
                    border = androidx.compose.foundation.BorderStroke(1.dp, IndigoLight),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f).testTag("copy_export_btn")
                ) {
                    Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Copy")
                }

                Button(
                    onClick = {
                        val sendIntent = android.content.Intent().apply {
                            action = android.content.Intent.ACTION_SEND
                            putExtra(android.content.Intent.EXTRA_TEXT, formattedContent)
                            type = "text/plain"
                        }
                        val shareIntent = android.content.Intent.createChooser(sendIntent, "Export session via")
                        context.startActivity(shareIntent)
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.weight(1f).testTag("share_export_btn")
                ) {
                    Icon(Icons.Default.Share, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(modifier = Modifier.width(6.dp))
                    Text("Share", fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
private fun ChatTabContent(
    session: Session,
    messages: List<ChatMessage>,
    isSending: Boolean,
    onSendMessage: (String, Boolean, Boolean) -> Unit
) {
    var queryText by remember { mutableStateOf("") }
    var selectedAiMode by remember { mutableStateOf(0) } // 0: Fast Lite, 1: High Thinking, 2: Grounded

    Column(modifier = Modifier.fillMaxSize()) {
        // AI Model selector row
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .background(DeepSlate)
                .padding(horizontal = 16.dp, vertical = 6.dp)
        ) {
            FilterChip(
                selected = selectedAiMode == 0,
                onClick = { selectedAiMode = 0 },
                label = { Text("⚡ Fast Flash-Lite", fontSize = 11.sp, fontWeight = FontWeight.Bold) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = EmeraldSuccess.copy(alpha = 0.25f),
                    selectedLabelColor = EmeraldSuccess,
                    containerColor = SurfaceDark,
                    labelColor = TextSecondary
                ),
                border = FilterChipDefaults.filterChipBorder(
                    enabled = true,
                    selected = selectedAiMode == 0,
                    borderColor = if (selectedAiMode == 0) EmeraldSuccess else SurfaceBorder
                ),
                modifier = Modifier.testTag("chip_fast_lite_mode")
            )

            FilterChip(
                selected = selectedAiMode == 1,
                onClick = { selectedAiMode = 1 },
                label = { Text("🧠 High Thinking Pro", fontSize = 11.sp, fontWeight = FontWeight.Bold) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = VioletAccent.copy(alpha = 0.25f),
                    selectedLabelColor = VioletAccent,
                    containerColor = SurfaceDark,
                    labelColor = TextSecondary
                ),
                border = FilterChipDefaults.filterChipBorder(
                    enabled = true,
                    selected = selectedAiMode == 1,
                    borderColor = if (selectedAiMode == 1) VioletAccent else SurfaceBorder
                ),
                modifier = Modifier.testTag("chip_high_thinking_mode")
            )
        }

        // Suggested quick prompt chips
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 6.dp)
        ) {
            listOf(
                "What are my open tasks?",
                "What decisions were made?",
                "Deep strategic analysis of risk",
                "Provide an executive brief"
            ).forEach { suggestion ->
                AssistChip(
                    onClick = {
                        onSendMessage(suggestion, selectedAiMode == 1, selectedAiMode == 0)
                    },
                    label = { Text(suggestion, fontSize = 12.sp) },
                    colors = AssistChipDefaults.assistChipColors(containerColor = SurfaceDark, labelColor = TextSecondary)
                )
            }
        }

        // Messages list
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.weight(1f).fillMaxWidth()
        ) {
            if (messages.isEmpty()) {
                item {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier.fillMaxWidth().padding(top = 40.dp)
                    ) {
                        Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(36.dp))
                        Spacer(modifier = Modifier.height(10.dp))
                        Text("Ask your Knowledge Companion anything", fontWeight = FontWeight.Bold, color = TextPrimary)
                        Text(
                            text = if (selectedAiMode == 1) "🧠 High Thinking Mode: gemini-3.1-pro-preview reasoning" else "⚡ Low-Latency Mode: gemini-3.1-flash-lite streaming",
                            fontSize = 12.sp,
                            color = IndigoLight
                        )
                    }
                }
            } else {
                items(messages, key = { it.id }) { msg ->
                    val isUser = msg.role == ChatRole.USER
                    Column(
                        horizontalAlignment = if (isUser) Alignment.End else Alignment.Start,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Surface(
                            color = if (isUser) IndigoPrimary else SurfaceDark,
                            shape = RoundedCornerShape(16.dp),
                            border = if (!isUser) androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder) else null,
                            modifier = Modifier.widthIn(max = 300.dp)
                        ) {
                            Column(modifier = Modifier.padding(12.dp)) {
                                Text(
                                    text = msg.content,
                                    color = if (isUser) Color.White else TextPrimary,
                                    fontSize = 14.sp,
                                    lineHeight = 20.sp
                                )

                                if (msg.citations.isNotEmpty()) {
                                    Spacer(modifier = Modifier.height(6.dp))
                                    Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        msg.citations.forEach { cite ->
                                            Text(
                                                text = cite,
                                                color = IndigoLight,
                                                fontSize = 10.sp,
                                                fontWeight = FontWeight.Bold
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Chat Input Bar
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .background(SurfaceDark)
                .padding(horizontal = 12.dp, vertical = 8.dp)
        ) {
            OutlinedTextField(
                value = queryText,
                onValueChange = { queryText = it },
                placeholder = {
                    Text(
                        if (selectedAiMode == 1) "Ask High Thinking deep question..." else "Ask fast low-latency question...",
                        color = TextMuted,
                        fontSize = 13.sp
                    )
                },
                singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = DeepSlate,
                    unfocusedContainerColor = DeepSlate,
                    focusedBorderColor = IndigoPrimary,
                    unfocusedBorderColor = SurfaceBorder,
                    focusedTextColor = TextPrimary,
                    unfocusedTextColor = TextPrimary
                ),
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.weight(1f).testTag("chat_input_field")
            )

            Spacer(modifier = Modifier.width(8.dp))

            IconButton(
                onClick = {
                    if (queryText.isNotBlank()) {
                        onSendMessage(queryText, selectedAiMode == 1, selectedAiMode == 0)
                        queryText = ""
                    }
                },
                enabled = queryText.isNotBlank() && !isSending,
                colors = IconButtonDefaults.iconButtonColors(containerColor = IndigoPrimary),
                modifier = Modifier.size(44.dp).testTag("send_chat_btn")
            ) {
                if (isSending) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                } else {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.Send,
                        contentDescription = "Send",
                        tint = Color.White,
                        modifier = Modifier.size(18.dp)
                    )
                }
            }
        }
    }
}

@Composable
private fun CommandsTabContent(
    session: Session,
    drafts: List<CommandDraft>,
    isRunning: Boolean,
    onRunCommand: (String) -> Unit,
    onOpenDraft: (String) -> Unit
) {
    val commands = listOf(
        Pair("meeting_minutes", "Meeting Minutes"),
        Pair("action_plan", "Action Plan"),
        Pair("executive_summary", "Executive Summary"),
        Pair("email_draft", "Email Draft"),
        Pair("presentation_outline", "Presentation Outline"),
        Pair("blog_post", "Blog Post"),
        Pair("rewrite_professional", "Professional Rewrite"),
        Pair("shorten_summary", "TL;DR Summary")
    )

    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        item {
            Text(
                text = "AI Command Bus",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = TextPrimary
            )
            Text(
                text = "Generate structured drafts without locking or automatically overriding source knowledge.",
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary
            )
        }

        // Quick command chips grid
        item {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                commands.chunked(2).forEach { rowCmds ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        rowCmds.forEach { (cmdKey, cmdLabel) ->
                            Button(
                                onClick = { onRunCommand(cmdKey) },
                                enabled = !isRunning,
                                colors = ButtonDefaults.buttonColors(containerColor = SurfaceDark),
                                border = androidx.compose.foundation.BorderStroke(1.dp, IndigoPrimary.copy(alpha = 0.5f)),
                                shape = RoundedCornerShape(12.dp),
                                modifier = Modifier.weight(1f).testTag("cmd_btn_$cmdKey")
                            ) {
                                Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(14.dp))
                                Spacer(modifier = Modifier.width(6.dp))
                                Text(cmdLabel, fontSize = 12.sp, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }

        if (drafts.isNotEmpty()) {
            item {
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = "Generated Drafts (${drafts.size})",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
            }

            items(drafts, key = { it.id }) { draft ->
                Card(
                    onClick = { onOpenDraft(draft.id) },
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth().testTag("draft_card_${draft.id}")
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(14.dp)
                    ) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(40.dp)
                                .clip(CircleShape)
                                .background(IndigoPrimary.copy(alpha = 0.2f))
                        ) {
                            Icon(Icons.Default.Description, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(20.dp))
                        }
                        Spacer(modifier = Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = draft.title,
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                            Text(
                                text = "Created: ${java.text.SimpleDateFormat("MMM dd, HH:mm").format(java.util.Date(draft.createdAt))}",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary,
                                fontSize = 11.sp
                            )
                        }
                        Icon(Icons.Default.ChevronRight, contentDescription = null, tint = TextMuted)
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryTabContent(
    versions: List<SessionVersion>,
    onRestore: (SessionVersion) -> Unit
) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier.fillMaxSize()
    ) {
        item {
            Text(
                text = "Version History & Provenance",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = TextPrimary
            )
            Text(
                text = "Every AI stage and manual edit records an immutable snapshot. Restore any state anytime.",
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary
            )
        }

        if (versions.isEmpty()) {
            item {
                Text("No past versions recorded yet.", color = TextMuted, fontSize = 13.sp)
            }
        } else {
            items(versions, key = { it.id }) { ver ->
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth().testTag("version_item_${ver.id}")
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.padding(14.dp)
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = ver.changeDescription,
                                style = MaterialTheme.typography.titleSmall,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                            Text(
                                text = "Snapshot at ${java.text.SimpleDateFormat("MMM dd, yyyy • HH:mm:ss").format(java.util.Date(ver.createdAt))}",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary,
                                fontSize = 11.sp
                            )
                        }

                        Button(
                            onClick = { onRestore(ver) },
                            colors = ButtonDefaults.buttonColors(containerColor = SurfaceCard),
                            shape = RoundedCornerShape(8.dp),
                            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
                            modifier = Modifier.testTag("restore_btn_${ver.id}")
                        ) {
                            Text("Restore", fontSize = 11.sp, color = IndigoLight, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }
        }
    }
}
