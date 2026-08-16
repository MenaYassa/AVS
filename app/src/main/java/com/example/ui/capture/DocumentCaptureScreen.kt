package com.example.ui.capture

import android.app.Application
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.data.engine.AiKnowledgeEngine
import com.example.data.ocr.RealOcrParser
import com.example.data.repository.KnowledgeRepository
import com.example.ui.theme.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class BatchDocumentItem(
    val id: String,
    val name: String,
    val text: String
)

data class DocPreset(
    val title: String,
    val sourceName: String,
    val type: String,
    val icon: androidx.compose.ui.graphics.vector.ImageVector,
    val extractedText: String
)

class DocumentCaptureViewModel(application: Application) : AndroidViewModel(application) {
    private val repository = KnowledgeRepository.getInstance(application)

    private val _isOcrProcessing = MutableStateFlow(false)
    val isOcrProcessing: StateFlow<Boolean> = _isOcrProcessing.asStateFlow()

    private val _extractedText = MutableStateFlow("")
    val extractedText: StateFlow<String> = _extractedText.asStateFlow()

    private val _currentSourceName = MutableStateFlow("Document")
    val currentSourceName: StateFlow<String> = _currentSourceName.asStateFlow()

    private val _statusMessage = MutableStateFlow<String?>(null)
    val statusMessage: StateFlow<String?> = _statusMessage.asStateFlow()

    private val _batchItems = MutableStateFlow<List<BatchDocumentItem>>(emptyList())
    val batchItems: StateFlow<List<BatchDocumentItem>> = _batchItems.asStateFlow()

    fun selectPreset(preset: DocPreset) {
        _currentSourceName.value = preset.sourceName
        _extractedText.value = preset.extractedText
        _statusMessage.value = "Loaded preset: ${preset.title}"
    }

    fun addCurrentToBatch() {
        val text = _extractedText.value
        val name = _currentSourceName.value
        if (text.isNotBlank()) {
            val item = BatchDocumentItem(
                id = "doc_${System.currentTimeMillis()}",
                name = if (name.isNotBlank()) name else "Page ${_batchItems.value.size + 1}",
                text = text
            )
            _batchItems.value = _batchItems.value + item
            _extractedText.value = ""
            _currentSourceName.value = "Next Page / Document"
            _statusMessage.value = "Added '${item.name}' to batch (${_batchItems.value.size} items)"
        }
    }

    fun removeBatchItem(id: String) {
        _batchItems.value = _batchItems.value.filter { it.id != id }
    }

    fun processCapturedBitmap(context: Context, bitmap: android.graphics.Bitmap) {
        _isOcrProcessing.value = true
        _statusMessage.value = "Performing Vision OCR extraction on camera photo..."
        _currentSourceName.value = "Camera Photo (Page ${_batchItems.value.size + 1})"
        viewModelScope.launch {
            val result = RealOcrParser.extractTextFromBitmap(context, bitmap)
            _isOcrProcessing.value = false
            result.onSuccess { text ->
                _extractedText.value = text
                _statusMessage.value = "Successfully extracted ${text.length} characters"
            }.onFailure { error ->
                _statusMessage.value = "OCR Error: ${error.message}"
            }
        }
    }

    fun processImageUri(context: Context, uri: Uri) {
        _isOcrProcessing.value = true
        _statusMessage.value = "Performing Vision OCR extraction..."
        _currentSourceName.value = "Image Capture"
        viewModelScope.launch {
            val result = RealOcrParser.extractTextFromImageUri(context, uri)
            _isOcrProcessing.value = false
            result.onSuccess { text ->
                _extractedText.value = text
                _statusMessage.value = "Successfully extracted ${text.length} characters"
            }.onFailure { error ->
                _statusMessage.value = "OCR Error: ${error.message}"
            }
        }
    }

    fun processDocumentUri(context: Context, uri: Uri) {
        _isOcrProcessing.value = true
        _statusMessage.value = "Reading and parsing document..."

        var fileName = "Selected Document"
        try {
            context.contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIdx >= 0) {
                        fileName = cursor.getString(nameIdx)
                    }
                }
            }
        } catch (e: Exception) {
            // Ignore
        }
        _currentSourceName.value = fileName

        viewModelScope.launch {
            val result = RealOcrParser.extractTextFromDocumentUri(context, uri, fileName)
            _isOcrProcessing.value = false
            result.onSuccess { text ->
                _extractedText.value = text
                _statusMessage.value = "Successfully loaded $fileName"
            }.onFailure { error ->
                _statusMessage.value = "Failed to parse $fileName: ${error.message}"
            }
        }
    }

    fun updateExtractedText(text: String) {
        _extractedText.value = text
    }

    fun synthesizeAndSave(onComplete: (String) -> Unit) {
        _isOcrProcessing.value = true
        _statusMessage.value = "Structuring knowledge with AI Knowledge Engine..."
        viewModelScope.launch {
            val batch = _batchItems.value
            val currentText = _extractedText.value

            val session = if (batch.isNotEmpty()) {
                val allDocs = batch.map { Pair(it.name, it.text) } +
                        if (currentText.isNotBlank()) listOf(Pair(_currentSourceName.value, currentText)) else emptyList()
                repository.saveBatchSession(allDocs)
            } else {
                val source = _currentSourceName.value
                val s = AiKnowledgeEngine.analyze(currentText)
                    .copy(title = if (source.isNotBlank() && source != "Document") source.substringBeforeLast(".") else "Document Intelligence")
                repository.saveSession(s)
                repository.createVersionSnapshot(s, "Synthesized from $source")
                s
            }

            _isOcrProcessing.value = false
            onComplete(session.id)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DocumentCaptureScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: DocumentCaptureViewModel = viewModel()
) {
    val context = LocalContext.current
    val isOcrProcessing by viewModel.isOcrProcessing.collectAsState()
    val extractedText by viewModel.extractedText.collectAsState()
    val currentSourceName by viewModel.currentSourceName.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()
    val batchItems by viewModel.batchItems.collectAsState()

    var hasCameraPermission by remember {
        mutableStateOf(
            androidx.core.content.ContextCompat.checkSelfPermission(
                context,
                android.Manifest.permission.CAMERA
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        )
    }

    val cameraPreviewLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.TakePicturePreview()
    ) { bitmap ->
        if (bitmap != null) {
            viewModel.processCapturedBitmap(context, bitmap)
        }
    }

    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        hasCameraPermission = isGranted
        if (isGranted) {
            try {
                cameraPreviewLauncher.launch(null)
            } catch (e: Exception) {
                Toast.makeText(context, "Could not open camera: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        } else {
            Toast.makeText(context, "Camera permission is required to capture photos", Toast.LENGTH_SHORT).show()
        }
    }

    fun launchCameraCapture() {
        if (hasCameraPermission) {
            try {
                cameraPreviewLauncher.launch(null)
            } catch (e: Exception) {
                Toast.makeText(context, "Could not open camera: ${e.message}", Toast.LENGTH_SHORT).show()
            }
        } else {
            cameraPermissionLauncher.launch(android.Manifest.permission.CAMERA)
        }
    }

    val galleryLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.processImageUri(context, it) }
    }

    val documentLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.processDocumentUri(context, it) }
    }

    val presets = remember {
        listOf(
            DocPreset(
                title = "Whiteboard Architecture Snapshot",
                sourceName = "whiteboard_sync_camera.jpg",
                type = "Image OCR",
                icon = Icons.Default.CameraAlt,
                extractedText = "Whiteboard Architecture Review:\n1. Universal Input Pipeline (Voice, PDF, Notes, EML)\n2. Deterministic stage orchestration (Cleanup -> Entity -> Graph -> Validation)\n3. Storage: Local SQLite Room + Supabase pgvector\nDecision: Elena to lead OAuth2 plugin credentials. Sarah to benchmark embedding retrieval."
            ),
            DocPreset(
                title = "Project Specification & Roadmap.pdf",
                sourceName = "architecture_spec_v2.pdf",
                type = "PDF Document",
                icon = Icons.Default.PictureAsPdf,
                extractedText = "Product Specification:\nExecutive Objectives: Provide instant recall of thoughts with confidence scoring.\nTarget Milestones: P6-A Semantic Search, P6-B Related Sessions, P6-C Cross-session Insights.\nTask: Ahmed to configure Redis memory buffer before peak load testing."
            ),
            DocPreset(
                title = "Client Strategy Alignment Email.eml",
                sourceName = "client_thread_fwd.eml",
                type = "Email File",
                icon = Icons.Default.Email,
                extractedText = "From: client-success@partner.io\nSubject: Feedback on Companion Prototype\nWe tested the meeting minutes generator and Notion push targets. The output was remarkably coherent. Can we support Slack thread summarization next? Next meeting scheduled for Thursday 2 PM."
            )
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text("Import & Batch OCR", fontWeight = FontWeight.Bold, color = TextPrimary)
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack, modifier = Modifier.testTag("capture_back_btn")) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = TextPrimary)
                    }
                },
                actions = {
                    Button(
                        onClick = {
                            viewModel.synthesizeAndSave { sessionId ->
                                onNavigateToSession(sessionId)
                            }
                        },
                        enabled = (extractedText.isNotBlank() || batchItems.isNotEmpty()) && !isOcrProcessing,
                        colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier
                            .padding(end = 12.dp)
                            .testTag("synthesize_doc_btn")
                    ) {
                        if (isOcrProcessing) {
                            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                        } else {
                            Icon(Icons.Default.AutoAwesome, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(modifier = Modifier.width(6.dp))
                            Text(
                                text = if (batchItems.isNotEmpty()) "Synthesize (${batchItems.size + if (extractedText.isNotBlank()) 1 else 0})" else "Synthesize",
                                fontWeight = FontWeight.Bold
                            )
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
            // Live Real Actions (Camera, Local Gallery, File Browser)
            Text(
                text = "Capture or Select Local Files",
                style = MaterialTheme.typography.labelMedium,
                color = TextSecondary,
                fontWeight = FontWeight.Bold
            )

            Spacer(modifier = Modifier.height(10.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                // 1. Camera Real Capture
                CaptureActionCard(
                    title = "Camera",
                    subtitle = "Snap whiteboard",
                    icon = Icons.Default.CameraAlt,
                    iconTint = VioletAccent,
                    onClick = { launchCameraCapture() },
                    modifier = Modifier.weight(1f).testTag("action_take_photo")
                )

                // 2. Photo Gallery
                CaptureActionCard(
                    title = "Photos",
                    subtitle = "Browse images",
                    icon = Icons.Default.Image,
                    iconTint = IndigoLight,
                    onClick = { galleryLauncher.launch("image/*") },
                    modifier = Modifier.weight(1f).testTag("action_pick_photo")
                )

                // 3. Local Files / Documents
                CaptureActionCard(
                    title = "Files",
                    subtitle = "PDF, DOCX, TXT",
                    icon = Icons.Default.FolderOpen,
                    iconTint = EmeraldSuccess,
                    onClick = { documentLauncher.launch("*/*") },
                    modifier = Modifier.weight(1f).testTag("action_pick_document")
                )
            }

            // Multi-Page Batch Queue Bar
            if (batchItems.isNotEmpty()) {
                Spacer(modifier = Modifier.height(16.dp))
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = BorderStroke(1.dp, IndigoLight.copy(alpha = 0.5f)),
                    shape = RoundedCornerShape(14.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(modifier = Modifier.padding(12.dp)) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = "Multi-Page Batch Queue (${batchItems.size} pages)",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                                color = IndigoLight
                            )
                            Text(
                                text = "All pages will combine into 1 session",
                                fontSize = 10.sp,
                                color = TextMuted
                            )
                        }
                        Spacer(modifier = Modifier.height(8.dp))
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            items(batchItems, key = { it.id }) { item ->
                                Surface(
                                    color = SurfaceCard,
                                    shape = RoundedCornerShape(8.dp),
                                    border = BorderStroke(1.dp, SurfaceBorder)
                                ) {
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp)
                                    ) {
                                        Text(item.name, fontSize = 12.sp, color = TextPrimary)
                                        Spacer(modifier = Modifier.width(6.dp))
                                        IconButton(
                                            onClick = { viewModel.removeBatchItem(item.id) },
                                            modifier = Modifier.size(18.dp)
                                        ) {
                                            Icon(Icons.Default.Close, contentDescription = "Remove", tint = RoseError, modifier = Modifier.size(14.dp))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(18.dp))

            // Presets Header
            Text(
                text = "Or Test with Sample Presets",
                style = MaterialTheme.typography.labelMedium,
                color = TextSecondary,
                fontWeight = FontWeight.SemiBold
            )

            Spacer(modifier = Modifier.height(10.dp))

            // Presets Cards
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                presets.forEach { preset ->
                    val isSelected = currentSourceName == preset.sourceName
                    Card(
                        onClick = { viewModel.selectPreset(preset) },
                        colors = CardDefaults.cardColors(
                            containerColor = if (isSelected) SurfaceCard else SurfaceDark
                        ),
                        border = BorderStroke(
                            1.dp,
                            if (isSelected) IndigoLight else SurfaceBorder
                        ),
                        shape = RoundedCornerShape(14.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .testTag("doc_preset_${preset.type.lowercase().replace(" ", "_")}")
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(12.dp)
                        ) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(36.dp)
                                    .clip(CircleShape)
                                    .background(if (isSelected) IndigoPrimary.copy(alpha = 0.2f) else SurfaceCard)
                            ) {
                                Icon(
                                    imageVector = preset.icon,
                                    contentDescription = null,
                                    tint = if (isSelected) IndigoLight else TextSecondary,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                            Spacer(modifier = Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = preset.title,
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.Bold,
                                    color = TextPrimary
                                )
                                Text(
                                    text = "${preset.type} • ${preset.sourceName}",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = TextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            if (isSelected) {
                                Icon(Icons.Default.CheckCircle, contentDescription = "Selected", tint = EmeraldSuccess, modifier = Modifier.size(20.dp))
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(18.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = "Extracted Content ($currentSourceName)",
                    style = MaterialTheme.typography.labelMedium,
                    color = TextSecondary,
                    fontWeight = FontWeight.SemiBold
                )
                if (extractedText.isNotBlank()) {
                    OutlinedButton(
                        onClick = { viewModel.addCurrentToBatch() },
                        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Icon(Icons.Default.AddToPhotos, contentDescription = null, tint = IndigoLight, modifier = Modifier.size(14.dp))
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("+ Add Page to Batch", fontSize = 11.sp, color = IndigoLight)
                    }
                }
            }

            if (statusMessage != null) {
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = statusMessage ?: "",
                    fontSize = 12.sp,
                    color = if (isOcrProcessing) IndigoLight else TextSecondary
                )
            }

            Spacer(modifier = Modifier.height(10.dp))

            // Extracted text box
            OutlinedTextField(
                value = extractedText,
                onValueChange = { viewModel.updateExtractedText(it) },
                placeholder = { Text("OCR extracted text or document contents will appear here...", color = TextMuted) },
                minLines = 7,
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
                    .testTag("ocr_extracted_text_input")
            )

            Spacer(modifier = Modifier.height(16.dp))
        }
    }
}

@Composable
private fun CaptureActionCard(
    title: String,
    subtitle: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    iconTint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        onClick = onClick,
        colors = CardDefaults.cardColors(containerColor = SurfaceDark),
        border = BorderStroke(1.dp, SurfaceBorder),
        shape = RoundedCornerShape(14.dp),
        modifier = modifier
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 14.dp, horizontal = 8.dp)
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(iconTint.copy(alpha = 0.15f))
            ) {
                Icon(
                    imageVector = icon,
                    contentDescription = title,
                    tint = iconTint,
                    modifier = Modifier.size(20.dp)
                )
            }
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold,
                color = TextPrimary,
                fontSize = 13.sp
            )
            Text(
                text = subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = TextSecondary,
                fontSize = 10.sp
            )
        }
    }
}
