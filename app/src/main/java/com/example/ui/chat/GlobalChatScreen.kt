package com.example.ui.chat

import android.app.Application
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.model.ChatRole
import com.example.data.model.Session
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.util.UUID

data class GlobalChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val role: ChatRole,
    val text: String,
    val citations: List<String> = emptyList(),
    val timestamp: Long = System.currentTimeMillis()
)

class GlobalChatViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _messages = MutableStateFlow<List<GlobalChatMessage>>(
        listOf(
            GlobalChatMessage(
                role = ChatRole.ASSISTANT,
                text = "Hello! I am your Global AI Knowledge Companion. Ask me anything across all your voice recordings, imported documents, meeting notes, action items, and knowledge graphs."
            )
        )
    )
    val messages: StateFlow<List<GlobalChatMessage>> = _messages.asStateFlow()

    private val _isProcessing = MutableStateFlow(false)
    val isProcessing: StateFlow<Boolean> = _isProcessing.asStateFlow()

    private val _allSessions = MutableStateFlow<List<Session>>(emptyList())
    val allSessions: StateFlow<List<Session>> = _allSessions.asStateFlow()

    init {
        viewModelScope.launch {
            repository.allSessions.collect { sessions ->
                _allSessions.value = sessions
            }
        }
    }

    fun sendQuery(query: String, isDeepReasoning: Boolean = true) {
        if (query.isBlank()) return
        val userMsg = GlobalChatMessage(role = ChatRole.USER, text = query)
        _messages.value = _messages.value + userMsg
        _isProcessing.value = true

        viewModelScope.launch {
            kotlinx.coroutines.delay(if (isDeepReasoning) 1000 else 400)
            val (answer, citations) = AiKnowledgeEngine.answerGlobalRagQuery(_allSessions.value, query)
            val assistantMsg = GlobalChatMessage(
                role = ChatRole.ASSISTANT,
                text = answer,
                citations = citations
            )
            _messages.value = _messages.value + assistantMsg
            _isProcessing.value = false
        }
    }

    fun clearChat() {
        _messages.value = listOf(
            GlobalChatMessage(
                role = ChatRole.ASSISTANT,
                text = "Chat cleared. What knowledge would you like to retrieve or synthesize from your sessions?"
            )
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GlobalChatScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: GlobalChatViewModel = viewModel()
) {
    val messages by viewModel.messages.collectAsState()
    val isProcessing by viewModel.isProcessing.collectAsState()
    val allSessions by viewModel.allSessions.collectAsState()

    var inputText by remember { mutableStateOf("") }
    var isDeepReasoning by remember { mutableStateOf(true) }
    val listState = rememberLazyListState()

    LaunchedEffect(messages.size) {
        if (messages.isNotEmpty()) {
            listState.animateScrollToItem(messages.size - 1)
        }
    }

    val suggestedQuestions = listOf(
        "What are all open high-priority tasks across my sessions?",
        "Summarize recent architecture and design decisions",
        "Who are the key team members and collaborators mentioned?",
        "What are the main projects in my knowledge base?"
    )

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Ask Knowledge Base", fontWeight = FontWeight.Bold, color = TextPrimary, fontSize = 17.sp)
                            Spacer(modifier = Modifier.width(6.dp))
                            Surface(
                                color = IndigoPrimary.copy(alpha = 0.3f),
                                shape = RoundedCornerShape(6.dp)
                            ) {
                                Text(
                                    text = "RAG Copilot",
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = IndigoLight,
                                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                                )
                            }
                        }
                        Text(
                            text = "Indexing ${allSessions.size} knowledge sessions",
                            fontSize = 11.sp,
                            color = TextSecondary
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("global_chat_back_btn")) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.clearChat() }) {
                        Icon(Icons.Outlined.CleaningServices, contentDescription = "Clear Chat", tint = TextSecondary)
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
            // Deep Reasoning Toggle bar
            Surface(
                color = SurfaceDark,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(
                            imageVector = Icons.Default.Psychology,
                            contentDescription = null,
                            tint = if (isDeepReasoning) IndigoLight else TextMuted,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = if (isDeepReasoning) "Deep Graph RAG (Multi-Session Synthesis)" else "Fast Direct Search",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = if (isDeepReasoning) TextPrimary else TextSecondary
                        )
                    }
                    Switch(
                        checked = isDeepReasoning,
                        onCheckedChange = { isDeepReasoning = it },
                        modifier = Modifier.height(28.dp)
                    )
                }
            }

            // Chat Messages List
            LazyColumn(
                state = listState,
                contentPadding = PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
            ) {
                items(messages, key = { it.id }) { msg ->
                    val isUser = msg.role == ChatRole.USER
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
                    ) {
                        if (!isUser) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(32.dp)
                                    .clip(CircleShape)
                                    .background(Brush.linearGradient(listOf(IndigoPrimary, PurpleGlow)))
                            ) {
                                Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
                            }
                            Spacer(modifier = Modifier.width(8.dp))
                        }

                        Card(
                            colors = CardDefaults.cardColors(
                                containerColor = if (isUser) IndigoPrimary else SurfaceDark
                            ),
                            border = if (isUser) null else androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                            shape = RoundedCornerShape(
                                topStart = 16.dp,
                                topEnd = 16.dp,
                                bottomStart = if (isUser) 16.dp else 4.dp,
                                bottomEnd = if (isUser) 4.dp else 16.dp
                            ),
                            modifier = Modifier.widthIn(max = 320.dp)
                        ) {
                            Column(modifier = Modifier.padding(14.dp)) {
                                Text(
                                    text = msg.text,
                                    color = TextPrimary,
                                    fontSize = 14.sp,
                                    lineHeight = 21.sp
                                )

                                if (msg.citations.isNotEmpty()) {
                                    Spacer(modifier = Modifier.height(10.dp))
                                    HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.6f))
                                    Spacer(modifier = Modifier.height(8.dp))
                                    Text("Sources & Session Citations:", fontSize = 11.sp, fontWeight = FontWeight.Bold, color = IndigoLight)
                                    Spacer(modifier = Modifier.height(4.dp))
                                    msg.citations.forEach { citation ->
                                        Surface(
                                            color = SurfaceCard,
                                            shape = RoundedCornerShape(6.dp),
                                            modifier = Modifier.padding(vertical = 2.dp)
                                        ) {
                                            Row(
                                                verticalAlignment = Alignment.CenterVertically,
                                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                            ) {
                                                Icon(Icons.Default.BookmarkBorder, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(12.dp))
                                                Spacer(modifier = Modifier.width(4.dp))
                                                Text(citation, fontSize = 11.sp, color = TextPrimary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if (isProcessing) {
                    item {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(8.dp)
                        ) {
                            CircularProgressIndicator(color = IndigoLight, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                            Spacer(modifier = Modifier.width(10.dp))
                            Text("Traversing knowledge graph & synthesizing answer...", fontSize = 12.sp, color = IndigoLight)
                        }
                    }
                }
            }

            // Quick Prompt Suggestions Chips
            if (messages.size <= 2) {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    items(suggestedQuestions) { prompt ->
                        Surface(
                            color = SurfaceCard,
                            shape = RoundedCornerShape(16.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                            modifier = Modifier.clickable {
                                viewModel.sendQuery(prompt, isDeepReasoning)
                            }
                        ) {
                            Text(
                                text = prompt,
                                fontSize = 12.sp,
                                color = TextPrimary,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                            )
                        }
                    }
                }
            }

            // Input Row
            Surface(
                color = SurfaceDark,
                modifier = Modifier.fillMaxWidth().imePadding()
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 10.dp)
                ) {
                    OutlinedTextField(
                        value = inputText,
                        onValueChange = { inputText = it },
                        placeholder = { Text("Ask across all sessions...", color = TextMuted, fontSize = 14.sp) },
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = DeepSlate,
                            unfocusedContainerColor = DeepSlate,
                            focusedBorderColor = IndigoPrimary,
                            unfocusedBorderColor = SurfaceBorder,
                            focusedTextColor = TextPrimary,
                            unfocusedTextColor = TextPrimary
                        ),
                        shape = RoundedCornerShape(24.dp),
                        singleLine = true,
                        modifier = Modifier
                            .weight(1f)
                            .testTag("global_chat_input")
                    )

                    Spacer(modifier = Modifier.width(10.dp))

                    IconButton(
                        onClick = {
                            if (inputText.isNotBlank() && !isProcessing) {
                                val q = inputText
                                inputText = ""
                                viewModel.sendQuery(q, isDeepReasoning)
                            }
                        },
                        enabled = inputText.isNotBlank() && !isProcessing,
                        colors = IconButtonDefaults.iconButtonColors(containerColor = IndigoPrimary),
                        modifier = Modifier.size(46.dp).testTag("global_chat_send_btn")
                    ) {
                        Icon(Icons.Default.Send, contentDescription = "Send", tint = Color.White, modifier = Modifier.size(20.dp))
                    }
                }
            }
        }
    }
}
