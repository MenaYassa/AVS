package com.example.ui.settings

import android.app.Activity
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import com.example.data.firebase.FirebaseAuthManager
import com.example.data.firebase.FirestorePersistenceManager
import com.example.data.firebase.SyncStatus
import com.example.data.gemini.AiConfig
import com.example.data.gemini.AiConfigManager
import com.example.data.gemini.AiProviderMode
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    onNavigateBack: () -> Unit
) {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    val authManager = remember { FirebaseAuthManager.getInstance(context) }
    val repository = remember { KnowledgeRepository.getInstance(context) }
    val firestoreManager = remember { FirestorePersistenceManager(context, repository) }
    val aiConfigManager = remember { AiConfigManager.getInstance(context) }

    val userState by authManager.userState.collectAsState()
    val syncStatus by firestoreManager.syncStatus.collectAsState()
    val aiConfig by aiConfigManager.configState.collectAsState()

    var selectedMode by remember(aiConfig) { mutableStateOf(aiConfig.mode) }
    var llmBaseUrl by remember(aiConfig) { mutableStateOf(aiConfig.llmBaseUrl) }
    var llmApiKey by remember(aiConfig) { mutableStateOf(aiConfig.llmApiKey) }
    var llmModel by remember(aiConfig) { mutableStateOf(aiConfig.llmModel) }
    var isApiKeyVisible by remember { mutableStateOf(false) }

    var sttBaseUrl by remember(aiConfig) { mutableStateOf(aiConfig.sttBaseUrl) }
    var sttApiKey by remember(aiConfig) { mutableStateOf(aiConfig.sttApiKey) }
    var sttModel by remember(aiConfig) { mutableStateOf(aiConfig.sttModel) }
    var isSttApiKeyVisible by remember { mutableStateOf(false) }

    var isVerifyingLlm by remember { mutableStateOf(false) }
    var isVerifyingStt by remember { mutableStateOf(false) }
    var verifyStatusMessage by remember { mutableStateOf<String?>(null) }
    var isVerifySuccess by remember { mutableStateOf(false) }

    var isNotionConnected by remember { mutableStateOf(true) }
    var isSlackConnected by remember { mutableStateOf(true) }
    var isLocalFirstStrict by remember { mutableStateOf(true) }
    var isSemanticVectorSearchEnabled by remember { mutableStateOf(true) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("Engine Settings & Integrations", fontWeight = FontWeight.Bold, color = TextPrimary)
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("settings_back_btn")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = TextPrimary)
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
            // Firebase Auth & Cloud Sync Card
            Text("Google Account & Cloud Firestore", style = MaterialTheme.typography.labelMedium, color = TextSecondary, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(8.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, if (userState.isSignedIn) IndigoPrimary else SurfaceBorder),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Box(
                            contentAlignment = Alignment.Center,
                            modifier = Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .background(if (userState.isSignedIn) IndigoPrimary.copy(alpha = 0.2f) else SurfaceCard)
                        ) {
                            Icon(
                                imageVector = if (userState.isSignedIn) Icons.Default.AccountCircle else Icons.Default.CloudSync,
                                contentDescription = null,
                                tint = if (userState.isSignedIn) IndigoLight else TextSecondary,
                                modifier = Modifier.size(28.dp)
                            )
                        }

                        Spacer(modifier = Modifier.width(12.dp))

                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = if (userState.isSignedIn) (userState.displayName ?: "Google User") else "Google Cloud Sign-In",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = TextPrimary
                            )
                            Text(
                                text = if (userState.isSignedIn) (userState.email ?: "Firebase Authenticated") else "Connect Firebase Auth for multi-device Firestore sync",
                                style = MaterialTheme.typography.bodySmall,
                                color = TextSecondary,
                                fontSize = 12.sp
                            )
                        }
                    }

                    if (userState.isSignedIn) {
                        HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))

                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Sync Status", fontSize = 13.sp, color = TextSecondary)
                            val statusText = when (syncStatus) {
                                is SyncStatus.Syncing -> "Syncing to Firestore..."
                                is SyncStatus.Success -> "Cloud Synced ✓"
                                is SyncStatus.Error -> "Sync Error"
                                else -> "Cloud Ready"
                            }
                            Text(statusText, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = EmeraldSuccess)
                        }

                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Button(
                                onClick = {
                                    coroutineScope.launch {
                                        userState.userId?.let { uid ->
                                            firestoreManager.syncAll(uid)
                                            Toast.makeText(context, "Full Firestore sync completed!", Toast.LENGTH_SHORT).show()
                                        }
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                                shape = RoundedCornerShape(10.dp),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
                                modifier = Modifier
                                    .weight(1.1f)
                                    .height(42.dp)
                                    .testTag("sync_firestore_btn")
                            ) {
                                Icon(Icons.Default.CloudUpload, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Sync Now", fontSize = 12.sp, maxLines = 1)
                            }

                            Button(
                                onClick = {
                                    coroutineScope.launch {
                                        userState.userId?.let { uid ->
                                            val result = firestoreManager.restoreAllFromCloud(uid)
                                            result.onSuccess { count ->
                                                Toast.makeText(context, "Restored $count sessions from Google Cloud!", Toast.LENGTH_SHORT).show()
                                            }.onFailure { err ->
                                                Toast.makeText(context, "Restore failed: ${err.message}", Toast.LENGTH_SHORT).show()
                                            }
                                        }
                                    }
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = EmeraldSuccess.copy(alpha = 0.9f)),
                                shape = RoundedCornerShape(10.dp),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp),
                                modifier = Modifier
                                    .weight(1f)
                                    .height(42.dp)
                                    .testTag("restore_firestore_btn")
                            ) {
                                Icon(Icons.Default.CloudDownload, contentDescription = null, modifier = Modifier.size(15.dp))
                                Spacer(modifier = Modifier.width(4.dp))
                                Text("Restore", fontSize = 12.sp, maxLines = 1)
                            }

                            OutlinedButton(
                                onClick = {
                                    authManager.signOut()
                                    Toast.makeText(context, "Signed out of Google", Toast.LENGTH_SHORT).show()
                                },
                                shape = RoundedCornerShape(10.dp),
                                contentPadding = PaddingValues(horizontal = 10.dp, vertical = 10.dp),
                                modifier = Modifier
                                    .height(42.dp)
                                    .testTag("sign_out_btn")
                            ) {
                                Text("Sign Out", color = RoseError, fontSize = 12.sp, maxLines = 1)
                            }
                        }
                    } else {
                        var showGoogleAccountChooser by remember { mutableStateOf(false) }
                        val deviceGoogleAccounts = remember { authManager.getDeviceGoogleAccounts() }

                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            // Authentic Google Sign-in Button
                            Surface(
                                color = Color.White,
                                shape = RoundedCornerShape(12.dp),
                                shadowElevation = 2.dp,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        showGoogleAccountChooser = true
                                    }
                                    .testTag("google_sign_in_btn")
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.Center,
                                    modifier = Modifier.padding(vertical = 12.dp, horizontal = 16.dp)
                                ) {
                                    // Google "G" Logo Box
                                    Box(
                                        contentAlignment = Alignment.Center,
                                        modifier = Modifier.size(24.dp)
                                    ) {
                                        Text(
                                            text = "G",
                                            fontWeight = FontWeight.Black,
                                            fontSize = 20.sp,
                                            color = Color(0xFF4285F4)
                                        )
                                    }
                                    Spacer(modifier = Modifier.width(12.dp))
                                    Text(
                                        text = "Sign in with Google",
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 15.sp,
                                        color = Color(0xFF1F1F1F)
                                    )
                                }
                            }
                        }

                        if (showGoogleAccountChooser) {
                            com.example.ui.components.GoogleAccountChooserSheet(
                                availableAccounts = deviceGoogleAccounts,
                                onAccountSelected = { email, name ->
                                    showGoogleAccountChooser = false
                                    authManager.signInWithGoogleAccount(email, name)
                                    coroutineScope.launch {
                                        val uid = "google_${email.replace("@", "_at_").replace(".", "_")}"
                                        // 1. Pull & Restore all existing sessions from Google Cloud
                                        val restoreResult = firestoreManager.restoreAllFromCloud(uid)
                                        // 2. Sync local sessions
                                        firestoreManager.syncAll(uid)

                                        val restoredCount = restoreResult.getOrDefault(0)
                                        if (restoredCount > 0) {
                                            Toast.makeText(context, "Welcome back, $name! Restored $restoredCount sessions from Cloud.", Toast.LENGTH_LONG).show()
                                        } else {
                                            Toast.makeText(context, "Welcome back, $name! Google Cloud sync active.", Toast.LENGTH_SHORT).show()
                                        }
                                    }
                                },
                                onDismiss = { showGoogleAccountChooser = false }
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Custom STT & LLM AI Provider Configuration
            Text("AI Providers, Custom STT & LLM Endpoints", style = MaterialTheme.typography.labelMedium, color = TextSecondary, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(8.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, if (selectedMode != AiProviderMode.DEFAULT_GEMINI.name) IndigoPrimary else SurfaceBorder),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    // Header status
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column {
                            Text("Active AI Provider", fontWeight = FontWeight.Bold, color = TextPrimary)
                            Text(
                                text = when (selectedMode) {
                                    AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name -> "Custom OpenAI ($llmModel)"
                                    AiProviderMode.CUSTOM_GEMINI.name -> "Custom Gemini ($llmModel)"
                                    else -> "AI Studio Gemini (gemini-3.5-flash)"
                                },
                                fontSize = 12.sp,
                                color = if (selectedMode != AiProviderMode.DEFAULT_GEMINI.name) IndigoLight else EmeraldSuccess,
                                fontWeight = FontWeight.SemiBold
                            )
                        }

                        if (aiConfig.isVerified) {
                            Surface(
                                color = EmeraldSuccess.copy(alpha = 0.15f),
                                shape = RoundedCornerShape(8.dp),
                                border = androidx.compose.foundation.BorderStroke(1.dp, EmeraldSuccess.copy(alpha = 0.5f))
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                ) {
                                    Icon(Icons.Default.CheckCircle, contentDescription = null, tint = EmeraldSuccess, modifier = Modifier.size(12.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("Verified", fontSize = 11.sp, color = EmeraldSuccess, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }

                    HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))

                    // Mode Selection Tabs (Scrollable for all screen widths)
                    Text("Select AI Provider Mode", fontSize = 12.sp, color = TextSecondary, fontWeight = FontWeight.Medium)
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .horizontalScroll(rememberScrollState())
                    ) {
                        AiProviderMode.values().forEach { mode ->
                            val isSelected = selectedMode == mode.name
                            FilterChip(
                                selected = isSelected,
                                onClick = {
                                    selectedMode = mode.name
                                    verifyStatusMessage = null
                                    if (mode == AiProviderMode.DEFAULT_GEMINI) {
                                        aiConfigManager.resetToDefault()
                                        Toast.makeText(context, "Switched to AI Studio Gemini", Toast.LENGTH_SHORT).show()
                                    }
                                },
                                leadingIcon = {
                                    Icon(
                                        imageVector = when (mode) {
                                            AiProviderMode.DEFAULT_GEMINI -> Icons.Default.AutoAwesome
                                            AiProviderMode.CUSTOM_OPENAI_COMPATIBLE -> Icons.Default.Dns
                                            AiProviderMode.CUSTOM_GEMINI -> Icons.Default.Key
                                        },
                                        contentDescription = null,
                                        modifier = Modifier.size(16.dp),
                                        tint = if (isSelected) Color.White else IndigoLight
                                    )
                                },
                                label = {
                                    Text(
                                        when (mode) {
                                            AiProviderMode.DEFAULT_GEMINI -> "AI Studio Gemini"
                                            AiProviderMode.CUSTOM_OPENAI_COMPATIBLE -> "Custom OpenAI / Ollama"
                                            AiProviderMode.CUSTOM_GEMINI -> "Custom Gemini API"
                                        },
                                        fontSize = 12.sp,
                                        fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
                                    )
                                },
                                colors = FilterChipDefaults.filterChipColors(
                                    selectedContainerColor = IndigoPrimary,
                                    selectedLabelColor = Color.White,
                                    containerColor = SurfaceCard,
                                    labelColor = TextSecondary
                                )
                            )
                        }
                    }

                    if (selectedMode == AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name || selectedMode == AiProviderMode.CUSTOM_GEMINI.name) {
                        // Quick Preset Chips for 1-Tap Configuration
                        if (selectedMode == AiProviderMode.CUSTOM_OPENAI_COMPATIBLE.name) {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text("1-Tap Configuration Presets:", fontSize = 11.sp, color = TextSecondary, fontWeight = FontWeight.SemiBold)
                                Row(
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .horizontalScroll(rememberScrollState())
                                ) {
                                    SuggestionChip(
                                        onClick = {
                                            llmBaseUrl = "http://10.0.2.2:11434/v1"
                                            llmModel = "llama3.2"
                                            sttBaseUrl = "http://10.0.2.2:11434/v1"
                                            sttModel = "whisper"
                                            Toast.makeText(context, "Loaded Ollama Emulator preset", Toast.LENGTH_SHORT).show()
                                        },
                                        icon = { Icon(Icons.Default.Computer, contentDescription = null, modifier = Modifier.size(14.dp), tint = IndigoLight) },
                                        label = { Text("Ollama Local (10.0.2.2)", fontSize = 11.sp) }
                                    )
                                    SuggestionChip(
                                        onClick = {
                                            llmBaseUrl = "https://api.openai.com/v1"
                                            llmModel = "gpt-4o"
                                            sttBaseUrl = "https://api.openai.com/v1"
                                            sttModel = "whisper-1"
                                            Toast.makeText(context, "Loaded OpenAI preset", Toast.LENGTH_SHORT).show()
                                        },
                                        icon = { Icon(Icons.Default.Cloud, contentDescription = null, modifier = Modifier.size(14.dp), tint = EmeraldSuccess) },
                                        label = { Text("OpenAI Official", fontSize = 11.sp) }
                                    )
                                    SuggestionChip(
                                        onClick = {
                                            llmBaseUrl = "https://api.groq.com/openai/v1"
                                            llmModel = "llama-3.3-70b-versatile"
                                            sttBaseUrl = "https://api.groq.com/openai/v1"
                                            sttModel = "whisper-large-v3"
                                            Toast.makeText(context, "Loaded Groq preset", Toast.LENGTH_SHORT).show()
                                        },
                                        icon = { Icon(Icons.Default.Bolt, contentDescription = null, modifier = Modifier.size(14.dp), tint = AmberWarning) },
                                        label = { Text("Groq Ultra-Fast", fontSize = 11.sp) }
                                    )
                                    SuggestionChip(
                                        onClick = {
                                            llmBaseUrl = "https://openrouter.ai/api/v1"
                                            llmModel = "meta-llama/llama-3.3-70b-instruct"
                                            sttBaseUrl = "https://api.openai.com/v1"
                                            sttModel = "whisper-1"
                                            Toast.makeText(context, "Loaded OpenRouter preset", Toast.LENGTH_SHORT).show()
                                        },
                                        icon = { Icon(Icons.Default.Hub, contentDescription = null, modifier = Modifier.size(14.dp), tint = SkyInfo) },
                                        label = { Text("OpenRouter", fontSize = 11.sp) }
                                    )
                                }

                                Surface(
                                    color = SurfaceCard,
                                    shape = RoundedCornerShape(8.dp),
                                    modifier = Modifier.fillMaxWidth().padding(top = 2.dp)
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.padding(8.dp)
                                    ) {
                                        Icon(Icons.Default.Info, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(14.dp))
                                        Spacer(modifier = Modifier.width(6.dp))
                                        Text(
                                            text = "For Ollama: use 10.0.2.2:11434 on emulator or your host PC's Wi-Fi IP on physical device (e.g. 192.168.1.50:11434).",
                                            fontSize = 10.sp,
                                            color = TextSecondary,
                                            lineHeight = 14.sp
                                        )
                                    }
                                }
                            }
                        }

                        // LLM Settings
                        Text("1. LLM (Chat, Copilot & Reasoning) Settings", fontSize = 12.sp, color = IndigoLight, fontWeight = FontWeight.Bold)

                        OutlinedTextField(
                            value = llmBaseUrl,
                            onValueChange = { llmBaseUrl = it },
                            label = { Text("LLM Base URL") },
                            placeholder = { Text(if (selectedMode == AiProviderMode.CUSTOM_GEMINI.name) "https://generativelanguage.googleapis.com" else "https://api.openai.com/v1") },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        OutlinedTextField(
                            value = llmApiKey,
                            onValueChange = { llmApiKey = it },
                            label = { Text("LLM API Key") },
                            placeholder = { Text("sk-...") },
                            singleLine = true,
                            visualTransformation = if (isApiKeyVisible) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { isApiKeyVisible = !isApiKeyVisible }) {
                                    Icon(
                                        imageVector = if (isApiKeyVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                        contentDescription = "Toggle Key Visibility",
                                        tint = TextSecondary
                                    )
                                }
                            },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        OutlinedTextField(
                            value = llmModel,
                            onValueChange = { llmModel = it },
                            label = { Text("Selected LLM Model Name") },
                            placeholder = { Text(if (selectedMode == AiProviderMode.CUSTOM_GEMINI.name) "gemini-2.5-flash" else "gpt-4o / llama-3.3-70b") },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))

                        // STT Settings
                        Text("2. Speech-to-Text (STT) Settings", fontSize = 12.sp, color = IndigoLight, fontWeight = FontWeight.Bold)

                        OutlinedTextField(
                            value = sttBaseUrl,
                            onValueChange = { sttBaseUrl = it },
                            label = { Text("STT Base URL") },
                            placeholder = { Text("https://api.openai.com/v1") },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        OutlinedTextField(
                            value = sttApiKey,
                            onValueChange = { sttApiKey = it },
                            label = { Text("STT API Key (Optional - uses LLM Key if empty)") },
                            placeholder = { Text("Inherit LLM key or enter separate key") },
                            singleLine = true,
                            visualTransformation = if (isSttApiKeyVisible) VisualTransformation.None else PasswordVisualTransformation(),
                            trailingIcon = {
                                IconButton(onClick = { isSttApiKeyVisible = !isSttApiKeyVisible }) {
                                    Icon(
                                        imageVector = if (isSttApiKeyVisible) Icons.Default.Visibility else Icons.Default.VisibilityOff,
                                        contentDescription = "Toggle Key Visibility",
                                        tint = TextSecondary
                                    )
                                }
                            },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        OutlinedTextField(
                            value = sttModel,
                            onValueChange = { sttModel = it },
                            label = { Text("Selected STT Model Name") },
                            placeholder = { Text("whisper-1 / whisper-large-v3") },
                            singleLine = true,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedTextColor = TextPrimary,
                                unfocusedTextColor = TextPrimary,
                                focusedBorderColor = IndigoLight,
                                unfocusedBorderColor = SurfaceBorder
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        // Verification Feedback Banner
                        if (verifyStatusMessage != null) {
                            Surface(
                                color = if (isVerifySuccess) EmeraldSuccess.copy(alpha = 0.15f) else RoseError.copy(alpha = 0.15f),
                                shape = RoundedCornerShape(10.dp),
                                border = androidx.compose.foundation.BorderStroke(
                                    1.dp,
                                    if (isVerifySuccess) EmeraldSuccess.copy(alpha = 0.5f) else RoseError.copy(alpha = 0.5f)
                                ),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(12.dp)
                                ) {
                                    Icon(
                                        imageVector = if (isVerifySuccess) Icons.Default.CheckCircle else Icons.Default.Warning,
                                        contentDescription = null,
                                        tint = if (isVerifySuccess) EmeraldSuccess else RoseError,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(modifier = Modifier.width(8.dp))
                                    Text(
                                        text = verifyStatusMessage ?: "",
                                        color = if (isVerifySuccess) TextPrimary else RoseError,
                                        fontSize = 12.sp,
                                        lineHeight = 16.sp
                                    )
                                }
                            }
                        }

                        // Verify & Save Action Buttons
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            OutlinedButton(
                                onClick = {
                                    val candidateConfig = AiConfig(
                                        mode = selectedMode,
                                        llmBaseUrl = llmBaseUrl,
                                        llmApiKey = llmApiKey,
                                        llmModel = llmModel,
                                        sttBaseUrl = sttBaseUrl,
                                        sttApiKey = sttApiKey,
                                        sttModel = sttModel
                                    )
                                    isVerifyingLlm = true
                                    verifyStatusMessage = "Testing connection to $llmModel..."
                                    coroutineScope.launch {
                                        val res = aiConfigManager.verifyLlmConnection(candidateConfig)
                                        isVerifyingLlm = false
                                        res.onSuccess { msg ->
                                            isVerifySuccess = true
                                            verifyStatusMessage = msg
                                        }.onFailure { err ->
                                            isVerifySuccess = false
                                            verifyStatusMessage = "Connection failed: ${err.message ?: "Check URL & API Key"}"
                                        }
                                    }
                                },
                                enabled = !isVerifyingLlm,
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier.weight(1f).testTag("verify_llm_btn")
                            ) {
                                if (isVerifyingLlm) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = IndigoLight)
                                } else {
                                    Icon(Icons.Default.NetworkCheck, contentDescription = null, modifier = Modifier.size(16.dp))
                                }
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Verify LLM", fontSize = 12.sp)
                            }

                            OutlinedButton(
                                onClick = {
                                    val candidateConfig = AiConfig(
                                        mode = selectedMode,
                                        llmBaseUrl = llmBaseUrl,
                                        llmApiKey = llmApiKey,
                                        llmModel = llmModel,
                                        sttBaseUrl = sttBaseUrl,
                                        sttApiKey = sttApiKey,
                                        sttModel = sttModel
                                    )
                                    isVerifyingStt = true
                                    verifyStatusMessage = "Verifying STT endpoint ($sttModel)..."
                                    coroutineScope.launch {
                                        val res = aiConfigManager.verifySttConnection(candidateConfig)
                                        isVerifyingStt = false
                                        res.onSuccess { msg ->
                                            isVerifySuccess = true
                                            verifyStatusMessage = msg
                                        }.onFailure { err ->
                                            isVerifySuccess = false
                                            verifyStatusMessage = "STT test error: ${err.message}"
                                        }
                                    }
                                },
                                enabled = !isVerifyingStt,
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier.weight(1f).testTag("verify_stt_btn")
                            ) {
                                if (isVerifyingStt) {
                                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = IndigoLight)
                                } else {
                                    Icon(Icons.Default.Mic, contentDescription = null, modifier = Modifier.size(16.dp))
                                }
                                Spacer(modifier = Modifier.width(6.dp))
                                Text("Verify STT", fontSize = 12.sp)
                            }
                        }

                        Button(
                            onClick = {
                                val newConfig = AiConfig(
                                    mode = selectedMode,
                                    llmBaseUrl = llmBaseUrl,
                                    llmApiKey = llmApiKey,
                                    llmModel = llmModel,
                                    sttBaseUrl = sttBaseUrl,
                                    sttApiKey = sttApiKey,
                                    sttModel = sttModel,
                                    isVerified = isVerifySuccess,
                                    lastVerificationMessage = verifyStatusMessage ?: "Saved",
                                    lastVerificationTime = System.currentTimeMillis()
                                )
                                aiConfigManager.saveConfig(newConfig)
                                Toast.makeText(context, "AI Provider activated successfully!", Toast.LENGTH_SHORT).show()
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                            shape = RoundedCornerShape(10.dp),
                            modifier = Modifier.fillMaxWidth().testTag("save_ai_config_btn")
                        ) {
                            Icon(Icons.Default.Save, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text("Save & Activate Configuration", fontWeight = FontWeight.Bold)
                        }
                    } else {
                        // Default Gemini info
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Audio STT Model", color = TextSecondary, fontSize = 13.sp)
                                Text("gemini-3.5-flash", fontWeight = FontWeight.Bold, color = IndigoLight, fontSize = 13.sp)
                            }
                            HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Low-Latency Copilot", color = TextSecondary, fontSize = 13.sp)
                                Text("gemini-3.1-flash-lite", fontWeight = FontWeight.Bold, color = EmeraldSuccess, fontSize = 13.sp)
                            }
                            HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.SpaceBetween,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("High Thinking Mode", color = TextSecondary, fontSize = 13.sp)
                                Text("gemini-3.1-pro-preview", fontWeight = FontWeight.Bold, color = VioletAccent, fontSize = 13.sp)
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Integrations Card
            Text("Plugin Push Targets (§6.3)", style = MaterialTheme.typography.labelMedium, color = TextSecondary, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(8.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Notion Integration", fontWeight = FontWeight.Bold, color = TextPrimary)
                                Spacer(modifier = Modifier.width(6.dp))
                                Surface(
                                    color = if (isNotionConnected) EmeraldSuccess.copy(alpha = 0.15f) else TextMuted.copy(alpha = 0.15f),
                                    shape = RoundedCornerShape(4.dp)
                                ) {
                                    Text(
                                        text = if (isNotionConnected) "Configured" else "Disabled",
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = if (isNotionConnected) EmeraldSuccess else TextSecondary,
                                        modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp)
                                    )
                                }
                            }
                            Text("Sync meeting minutes and knowledge items to team workspace.", fontSize = 11.sp, color = TextSecondary)
                        }
                        Switch(
                            checked = isNotionConnected,
                            onCheckedChange = {
                                isNotionConnected = it
                                Toast.makeText(context, if (it) "Enabled Notion export target" else "Disabled Notion export target", Toast.LENGTH_SHORT).show()
                            },
                            colors = SwitchDefaults.colors(checkedThumbColor = IndigoLight, checkedTrackColor = IndigoPrimary)
                        )
                    }

                    HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f).padding(end = 12.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Slack Workspace", fontWeight = FontWeight.Bold, color = TextPrimary)
                                Spacer(modifier = Modifier.width(6.dp))
                                Surface(
                                    color = if (isSlackConnected) EmeraldSuccess.copy(alpha = 0.15f) else TextMuted.copy(alpha = 0.15f),
                                    shape = RoundedCornerShape(4.dp)
                                ) {
                                    Text(
                                        text = if (isSlackConnected) "Configured" else "Disabled",
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        color = if (isSlackConnected) EmeraldSuccess else TextSecondary,
                                        modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp)
                                    )
                                }
                            }
                            Text("Dispatch action items and executive summaries directly to channels.", fontSize = 11.sp, color = TextSecondary)
                        }
                        Switch(
                            checked = isSlackConnected,
                            onCheckedChange = {
                                isSlackConnected = it
                                Toast.makeText(context, if (it) "Enabled Slack export target" else "Disabled Slack export target", Toast.LENGTH_SHORT).show()
                            },
                            colors = SwitchDefaults.colors(checkedThumbColor = IndigoLight, checkedTrackColor = IndigoPrimary)
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // Privacy & Database
            Text("Privacy & Storage", style = MaterialTheme.typography.labelMedium, color = TextSecondary, fontWeight = FontWeight.Bold)
            Spacer(modifier = Modifier.height(8.dp))

            Card(
                colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Offline-First Privacy", fontWeight = FontWeight.Bold, color = TextPrimary)
                            Text("Store all raw audio, transcripts, and graph entities in encrypted local SQLite Room DB.", fontSize = 11.sp, color = TextSecondary)
                        }
                        Switch(
                            checked = isLocalFirstStrict,
                            onCheckedChange = { isLocalFirstStrict = it },
                            colors = SwitchDefaults.colors(checkedThumbColor = IndigoLight, checkedTrackColor = IndigoPrimary)
                        )
                    }

                    HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Semantic Vector Search", fontWeight = FontWeight.Bold, color = TextPrimary)
                            Text("Enable semantic cosine similarity indexing alongside FTS5 lexical search.", fontSize = 11.sp, color = TextSecondary)
                        }
                        Switch(
                            checked = isSemanticVectorSearchEnabled,
                            onCheckedChange = { isSemanticVectorSearchEnabled = it },
                            colors = SwitchDefaults.colors(checkedThumbColor = IndigoLight, checkedTrackColor = IndigoPrimary)
                        )
                    }
                }
            }
        }
    }
}
