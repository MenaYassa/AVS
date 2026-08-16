package com.example.ui.home

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.animation.*
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.model.Session
import com.example.ui.components.SessionActionsBottomSheet
import com.example.ui.components.SwipeableSessionCard
import com.example.ui.components.TagChip
import com.example.ui.theme.*
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onNavigateToRecord: () -> Unit,
    onNavigateToNote: () -> Unit,
    onNavigateToCapture: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    onNavigateToGlobalGraph: () -> Unit,
    onNavigateToInsights: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToGlobalChat: () -> Unit = {},
    onNavigateToSynthesis: () -> Unit = {},
    viewModel: HomeViewModel = viewModel()
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsState()
    val snackbarHostState = remember { SnackbarHostState() }
    val coroutineScope = rememberCoroutineScope()

    var showInputSheet by remember { mutableStateOf(false) }
    var selectedSessionForActions by remember { mutableStateOf<Session?>(null) }
    var sessionToRename by remember { mutableStateOf<Session?>(null) }
    var renameInputText by remember { mutableStateOf("") }

    val allTags = remember(uiState.sessions) {
        uiState.sessions.flatMap { it.tags }.distinct()
    }

    Scaffold(
        snackbarHost = {
            SnackbarHost(
                hostState = snackbarHostState,
                snackbar = { data ->
                    Snackbar(
                        snackbarData = data,
                        containerColor = SurfaceDark,
                        contentColor = TextPrimary,
                        actionColor = IndigoLight,
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.padding(12.dp)
                    )
                }
            )
        },
        topBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(DeepSlate)
                    .statusBarsPadding()
                    .padding(top = 4.dp)
            ) {
                // Header Row
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.weight(1f, fill = false)
                    ) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(36.dp)
                                .clip(CircleShape)
                                .background(
                                    Brush.linearGradient(
                                        listOf(IndigoPrimary, PurpleGlow)
                                    )
                                )
                        ) {
                            Icon(
                                imageVector = Icons.Default.Grain,
                                contentDescription = "Logo",
                                tint = Color.White,
                                modifier = Modifier.size(20.dp)
                            )
                        }
                        Spacer(modifier = Modifier.width(10.dp))
                        Column {
                            Text(
                                text = "AI Knowledge",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.ExtraBold,
                                color = TextPrimary,
                                letterSpacing = (-0.5).sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                            Text(
                                text = "Thought Companion",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary,
                                fontSize = 11.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis
                            )
                        }
                    }

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(2.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        IconButton(
                            onClick = onNavigateToGlobalChat,
                            modifier = Modifier.size(40.dp).testTag("global_chat_nav_btn")
                        ) {
                            BadgedBox(
                                badge = {
                                    Badge(containerColor = PurpleGlow) {
                                        Text("AI", fontSize = 8.sp, fontWeight = FontWeight.Bold)
                                    }
                                }
                            ) {
                                Icon(
                                    imageVector = Icons.Default.AutoAwesome,
                                    contentDescription = "Ask Knowledge Base",
                                    tint = IndigoLight,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                        }

                        IconButton(
                            onClick = onNavigateToInsights,
                            modifier = Modifier.size(40.dp).testTag("insights_nav_btn")
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Insights,
                                contentDescription = "Cross-Session Insights",
                                tint = TextPrimary,
                                modifier = Modifier.size(22.dp)
                            )
                        }

                        IconButton(
                            onClick = onNavigateToGlobalGraph,
                            modifier = Modifier.size(40.dp).testTag("global_graph_nav_btn")
                        ) {
                            Icon(
                                imageVector = Icons.Outlined.Hub,
                                contentDescription = "Global Knowledge Graph",
                                tint = TextPrimary,
                                modifier = Modifier.size(22.dp)
                            )
                        }

                        val authManager = remember { com.example.data.firebase.FirebaseAuthManager.getInstance(context) }
                        val userState by authManager.userState.collectAsState()

                        IconButton(
                            onClick = onNavigateToSettings,
                            modifier = Modifier.size(40.dp).testTag("settings_nav_btn")
                        ) {
                            if (userState.isSignedIn) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier
                                        .size(30.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFF4285F4))
                                ) {
                                    Text(
                                        text = (userState.displayName?.take(1) ?: "G").uppercase(),
                                        color = Color.White,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 14.sp
                                    )
                                }
                            } else {
                                Icon(
                                    imageVector = Icons.Outlined.Settings,
                                    contentDescription = "Settings",
                                    tint = TextPrimary,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                        }
                    }
                }

                // Search Bar
                OutlinedTextField(
                    value = uiState.searchQuery,
                    onValueChange = { viewModel.setSearchQuery(it) },
                    placeholder = { Text("Search thoughts, action items, tags, entities...", color = TextMuted, fontSize = 14.sp) },
                    leadingIcon = {
                        Icon(Icons.Default.Search, contentDescription = "Search", tint = TextSecondary)
                    },
                    trailingIcon = {
                        if (uiState.searchQuery.isNotEmpty()) {
                            IconButton(onClick = { viewModel.setSearchQuery("") }) {
                                Icon(Icons.Default.Clear, contentDescription = "Clear", tint = TextMuted)
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
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 20.dp, vertical = 6.dp)
                        .testTag("home_search_input")
                )

                // Category Filter Pills
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 20.dp, vertical = 8.dp)
                ) {
                    HomeFilter.entries.forEach { filter ->
                        FilterChip(
                            selected = uiState.filter == filter,
                            onClick = { viewModel.setFilter(filter) },
                            label = { Text(filter.label, fontWeight = FontWeight.Medium) },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = IndigoPrimary,
                                selectedLabelColor = Color.White,
                                containerColor = SurfaceDark,
                                labelColor = TextSecondary
                            ),
                            border = FilterChipDefaults.filterChipBorder(
                                enabled = true,
                                selected = uiState.filter == filter,
                                borderColor = if (uiState.filter == filter) IndigoLight else SurfaceBorder
                            ),
                            shape = RoundedCornerShape(12.dp),
                            modifier = Modifier.testTag("filter_chip_${filter.name.lowercase()}")
                        )
                    }
                }

                // Tags Horizontal Row
                if (allTags.isNotEmpty()) {
                    LazyRow(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 4.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        items(allTags) { tag ->
                            TagChip(
                                tag = tag,
                                selected = uiState.selectedTag == tag,
                                onClick = { viewModel.selectTag(tag) },
                                modifier = Modifier.testTag("tag_chip_$tag")
                            )
                        }
                    }
                }
            }
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { showInputSheet = true },
                containerColor = IndigoPrimary,
                contentColor = Color.White,
                shape = CircleShape,
                modifier = Modifier
                    .size(64.dp)
                    .testTag("add_knowledge_fab")
            ) {
                Icon(
                    imageVector = Icons.Default.Add,
                    contentDescription = "New Thought / Knowledge",
                    modifier = Modifier.size(32.dp)
                )
            }
        },
        containerColor = DeepSlate
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            if (uiState.sessions.isEmpty()) {
                // Empty state
                Column(
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(32.dp)
                ) {
                    Box(
                        contentAlignment = Alignment.Center,
                        modifier = Modifier
                            .size(90.dp)
                            .clip(CircleShape)
                            .background(SurfaceDark)
                    ) {
                        Icon(
                            imageVector = Icons.Default.MicNone,
                            contentDescription = null,
                            tint = IndigoLight,
                            modifier = Modifier.size(48.dp)
                        )
                    }
                    Spacer(modifier = Modifier.height(20.dp))
                    Text(
                        text = "Speak or write your thoughts",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "Swipe left to delete, swipe right to archive, or long press any card for options.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = TextSecondary,
                        textAlign = TextAlign.Center
                    )
                    Spacer(modifier = Modifier.height(24.dp))
                    Button(
                        onClick = onNavigateToRecord,
                        colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.testTag("start_recording_empty_btn")
                    ) {
                        Icon(Icons.Default.Mic, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(modifier = Modifier.width(8.dp))
                        Text("Record Voice Note", fontWeight = FontWeight.SemiBold)
                    }
                }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 12.dp, bottom = 88.dp),
                    verticalArrangement = Arrangement.spacedBy(14.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    item {
                        Card(
                            colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                            border = BorderStroke(1.dp, IndigoPrimary.copy(alpha = 0.4f)),
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .weight(1f)
                                        .clickable { onNavigateToGlobalChat() }
                                ) {
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier
                                            .size(34.dp)
                                            .clip(CircleShape)
                                            .background(Brush.linearGradient(listOf(IndigoPrimary, PurpleGlow)))
                                    ) {
                                        Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                                    }
                                    Spacer(modifier = Modifier.width(10.dp))
                                    Column {
                                        Text("Ask AI Copilot", fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 13.sp)
                                        Text("RAG across all sessions", color = TextSecondary, fontSize = 11.sp)
                                    }
                                }

                                VerticalDivider(modifier = Modifier.height(28.dp).padding(horizontal = 8.dp), color = SurfaceBorder)

                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier
                                        .weight(1f)
                                        .clickable { onNavigateToSynthesis() }
                                ) {
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier
                                            .size(34.dp)
                                            .clip(CircleShape)
                                            .background(SurfaceCard)
                                    ) {
                                        Icon(Icons.Default.Summarize, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(16.dp))
                                    }
                                    Spacer(modifier = Modifier.width(10.dp))
                                    Column {
                                        Text("Executive Brief", fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 13.sp)
                                        Text("Cross-session synthesis", color = TextSecondary, fontSize = 11.sp)
                                    }
                                }
                            }
                        }
                    }

                    items(uiState.sessions, key = { it.id }) { session ->
                        SwipeableSessionCard(
                            session = session,
                            onClick = { onNavigateToSession(session.id) },
                            onLongClick = { selectedSessionForActions = session },
                            onToggleFavorite = { viewModel.toggleFavorite(session) },
                            onTogglePin = { viewModel.togglePin(session) },
                            onSwipeArchive = {
                                val wasArchived = session.archived
                                if (wasArchived) {
                                    viewModel.unarchiveSession(session)
                                } else {
                                    viewModel.archiveSession(session)
                                }
                                coroutineScope.launch {
                                    snackbarHostState.currentSnackbarData?.dismiss()
                                    val actionMsg = if (wasArchived) "Restored from archive" else "Archived session"
                                    val result = snackbarHostState.showSnackbar(
                                        message = "$actionMsg: ${session.title ?: "Session"}",
                                        actionLabel = "Undo",
                                        duration = SnackbarDuration.Short
                                    )
                                    if (result == SnackbarResult.ActionPerformed) {
                                        if (wasArchived) {
                                            viewModel.archiveSession(session)
                                        } else {
                                            viewModel.unarchiveSession(session)
                                        }
                                    }
                                }
                            },
                            onSwipeDelete = {
                                viewModel.deleteSession(session)
                                coroutineScope.launch {
                                    snackbarHostState.currentSnackbarData?.dismiss()
                                    val result = snackbarHostState.showSnackbar(
                                        message = "Deleted: ${session.title ?: "Session"}",
                                        actionLabel = "Undo",
                                        duration = SnackbarDuration.Short
                                    )
                                    if (result == SnackbarResult.ActionPerformed) {
                                        viewModel.restoreSession(session)
                                    }
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    // Long Press / More Options Bottom Sheet
    selectedSessionForActions?.let { session ->
        SessionActionsBottomSheet(
            session = session,
            onDismiss = { selectedSessionForActions = null },
            onTogglePin = { viewModel.togglePin(session) },
            onToggleFavorite = { viewModel.toggleFavorite(session) },
            onToggleArchive = {
                val wasArchived = session.archived
                if (wasArchived) {
                    viewModel.unarchiveSession(session)
                } else {
                    viewModel.archiveSession(session)
                }
                coroutineScope.launch {
                    val msg = if (wasArchived) "Restored from archive" else "Archived"
                    val result = snackbarHostState.showSnackbar(
                        message = "$msg '${session.title}'",
                        actionLabel = "Undo",
                        duration = SnackbarDuration.Short
                    )
                    if (result == SnackbarResult.ActionPerformed) {
                        if (wasArchived) {
                            viewModel.archiveSession(session)
                        } else {
                            viewModel.unarchiveSession(session)
                        }
                    }
                }
            },
            onRename = {
                renameInputText = session.title ?: ""
                sessionToRename = session
            },
            onDuplicate = {
                viewModel.duplicateSession(session)
                coroutineScope.launch {
                    snackbarHostState.showSnackbar(
                        message = "Duplicated '${session.title}'",
                        duration = SnackbarDuration.Short
                    )
                }
            },
            onCopyContent = {
                val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val textToCopy = buildString {
                    appendLine(session.title ?: "Untitled Knowledge")
                    if (!session.summary.isNullOrBlank()) {
                        appendLine("\n[Summary]:")
                        appendLine(session.summary)
                    }
                    if (!session.cleanedTranscript.isNullOrBlank()) {
                        appendLine("\n[Content]:")
                        appendLine(session.cleanedTranscript)
                    }
                }
                clipboard.setPrimaryClip(ClipData.newPlainText("Knowledge Entry", textToCopy))
                Toast.makeText(context, "Content copied to clipboard", Toast.LENGTH_SHORT).show()
            },
            onDelete = {
                viewModel.deleteSession(session)
                coroutineScope.launch {
                    val result = snackbarHostState.showSnackbar(
                        message = "Deleted '${session.title}'",
                        actionLabel = "Undo",
                        duration = SnackbarDuration.Short
                    )
                    if (result == SnackbarResult.ActionPerformed) {
                        viewModel.restoreSession(session)
                    }
                }
            }
        )
    }

    // Rename Session Dialog
    sessionToRename?.let { session ->
        AlertDialog(
            onDismissRequest = { sessionToRename = null },
            title = { Text("Rename Entry", fontWeight = FontWeight.Bold) },
            text = {
                OutlinedTextField(
                    value = renameInputText,
                    onValueChange = { renameInputText = it },
                    label = { Text("Session Title") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = SurfaceDark,
                        unfocusedContainerColor = SurfaceDark
                    ),
                    modifier = Modifier.fillMaxWidth().testTag("rename_input_field")
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        if (renameInputText.isNotBlank()) {
                            viewModel.renameSession(session, renameInputText)
                            sessionToRename = null
                        }
                    },
                    modifier = Modifier.testTag("confirm_rename_btn")
                ) {
                    Text("Save")
                }
            },
            dismissButton = {
                TextButton(onClick = { sessionToRename = null }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Input Source Modal Bottom Sheet
    if (showInputSheet) {
        ModalBottomSheet(
            onDismissRequest = { showInputSheet = false },
            containerColor = SurfaceDark,
            dragHandle = { BottomSheetDefaults.DragHandle(color = SurfaceBorder) }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 24.dp, vertical = 16.dp)
            ) {
                Text(
                    text = "Capture Knowledge",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
                Text(
                    text = "Choose an input method for automatic AI structuring",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary
                )
                Spacer(modifier = Modifier.height(20.dp))

                // Option 1: Record Voice
                InputOptionRow(
                    icon = Icons.Default.Mic,
                    iconTint = IndigoLight,
                    title = "Record Spoken Thought",
                    subtitle = "Stream live audio, transcribe, clean fillers, and synthesize topics",
                    onClick = {
                        showInputSheet = false
                        onNavigateToRecord()
                    },
                    testTag = "option_voice_record"
                )

                Spacer(modifier = Modifier.height(12.dp))

                // Option 2: Write Note
                InputOptionRow(
                    icon = Icons.Default.EditNote,
                    iconTint = EmeraldSuccess,
                    title = "Write a Note",
                    subtitle = "Draft text or paste meeting notes for instant intelligence breakdown",
                    onClick = {
                        showInputSheet = false
                        onNavigateToNote()
                    },
                    testTag = "option_write_note"
                )

                Spacer(modifier = Modifier.height(12.dp))

                // Option 3: Document & Image OCR
                InputOptionRow(
                    icon = Icons.Default.DocumentScanner,
                    iconTint = VioletAccent,
                    title = "Import Document / Image (OCR)",
                    subtitle = "Extract and structure content from PDF, Word, Email, or Whiteboard photo",
                    onClick = {
                        showInputSheet = false
                        onNavigateToCapture()
                    },
                    testTag = "option_doc_capture"
                )

                Spacer(modifier = Modifier.height(32.dp))
            }
        }
    }
}

@Composable
private fun InputOptionRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconTint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    testTag: String
) {
    Card(
        onClick = onClick,
        colors = CardDefaults.cardColors(containerColor = SurfaceCard),
        shape = RoundedCornerShape(16.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.6f)),
        modifier = Modifier
            .fillMaxWidth()
            .testTag(testTag)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(16.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .background(iconTint.copy(alpha = 0.15f))
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = null,
                    tint = iconTint,
                    modifier = Modifier.size(24.dp)
                )
            }
            Spacer(modifier = Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                    fontSize = 12.sp
                )
            }
            Icon(
                imageVector = Icons.Default.ChevronRight,
                contentDescription = null,
                tint = TextMuted
            )
        }
    }
}
