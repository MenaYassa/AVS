package com.example.ui.recording

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import com.example.ui.components.AudioWaveform
import com.example.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecordingScreen(
    onNavigateBack: () -> Unit,
    onNavigateToSession: (String) -> Unit,
    viewModel: RecordingViewModel = viewModel()
) {
    val context = LocalContext.current
    val uiState by viewModel.uiState.collectAsState()

    var hasPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO
            ) == PackageManager.PERMISSION_GRANTED
        )
    }

    var permissionRequested by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        hasPermission = isGranted
        permissionRequested = true
        if (isGranted) {
            viewModel.startRecording()
        }
    }

    LaunchedEffect(Unit) {
        if (!hasPermission) {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        } else if (uiState.state == RecordingState.IDLE) {
            viewModel.startRecording()
        }
    }

    LaunchedEffect(uiState.state, uiState.createdSessionId) {
        if (uiState.state == RecordingState.COMPLETED && uiState.createdSessionId != null) {
            onNavigateToSession(uiState.createdSessionId!!)
        }
    }

    val mins = uiState.elapsedSeconds / 60
    val secs = uiState.elapsedSeconds % 60
    val formattedTime = String.format("%02d:%02d", mins, secs)

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = if (uiState.state == RecordingState.PROCESSING) "AI Knowledge Pipeline" else "Live Voice Capture",
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = {
                            viewModel.cancelRecording()
                            onNavigateBack()
                        },
                        modifier = Modifier.testTag("record_back_btn")
                    ) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = TextPrimary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = DeepSlate)
            )
        },
        containerColor = DeepSlate
    ) { padding ->
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp)
        ) {
            if (!hasPermission) {
                // Permission required state
                Spacer(modifier = Modifier.weight(1f))

                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(96.dp)
                        .clip(CircleShape)
                        .background(RoseContainer.copy(alpha = 0.5f))
                ) {
                    Icon(
                        imageVector = Icons.Default.MicOff,
                        contentDescription = "Microphone Permission Required",
                        tint = RoseError,
                        modifier = Modifier.size(48.dp)
                    )
                }

                Spacer(modifier = Modifier.height(24.dp))

                Text(
                    text = "Microphone Access Required",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary,
                    textAlign = TextAlign.Center
                )

                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = "To record your voice and convert it into structured knowledge, action items, and topic maps, please allow microphone access.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = TextSecondary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(horizontal = 16.dp)
                )

                Spacer(modifier = Modifier.height(32.dp))

                Button(
                    onClick = {
                        permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier
                        .fillMaxWidth(0.85f)
                        .height(52.dp)
                        .testTag("grant_mic_permission_btn")
                ) {
                    Icon(Icons.Default.Mic, contentDescription = null, tint = Color.White)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Grant Microphone Access",
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                        fontSize = 15.sp
                    )
                }

                Spacer(modifier = Modifier.height(16.dp))

                OutlinedButton(
                    onClick = onNavigateBack,
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth(0.85f).height(48.dp)
                ) {
                    Text("Go Back", color = TextSecondary)
                }

                Spacer(modifier = Modifier.weight(1f))
            } else if (uiState.state == RecordingState.PROCESSING) {
                // Processing view
                Spacer(modifier = Modifier.weight(1f))
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(100.dp)
                        .clip(CircleShape)
                        .background(
                            Brush.linearGradient(listOf(IndigoPrimary, PurpleGlow))
                        )
                ) {
                    CircularProgressIndicator(
                        progress = { uiState.processingProgress },
                        color = Color.White,
                        strokeWidth = 4.dp,
                        modifier = Modifier.size(76.dp)
                    )
                    Icon(
                        imageVector = Icons.Default.AutoAwesome,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(36.dp)
                    )
                }

                Spacer(modifier = Modifier.height(28.dp))

                Text(
                    text = "Structuring Knowledge",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    color = TextPrimary
                )

                Spacer(modifier = Modifier.height(10.dp))

                Text(
                    text = uiState.processingStage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = IndigoLight,
                    textAlign = TextAlign.Center
                )

                Spacer(modifier = Modifier.height(24.dp))

                LinearProgressIndicator(
                    progress = { uiState.processingProgress },
                    color = IndigoPrimary,
                    trackColor = SurfaceCard,
                    modifier = Modifier
                        .fillMaxWidth(0.8f)
                        .height(8.dp)
                        .clip(RoundedCornerShape(4.dp))
                )

                Spacer(modifier = Modifier.weight(1f))
            } else {
                // Recording / Paused view
                Spacer(modifier = Modifier.height(16.dp))

                // Timer Display
                Text(
                    text = formattedTime,
                    fontSize = 48.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (uiState.state == RecordingState.RECORDING) Color.White else AmberWarning,
                    letterSpacing = 2.sp,
                    modifier = Modifier.testTag("record_timer_display")
                )

                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            if (uiState.state == RecordingState.RECORDING) RoseContainer.copy(alpha = 0.5f)
                            else AmberContainer.copy(alpha = 0.5f)
                        )
                        .padding(horizontal = 12.dp, vertical = 4.dp)
                ) {
                    Box(
                        modifier = Modifier
                            .size(8.dp)
                            .clip(CircleShape)
                            .background(if (uiState.state == RecordingState.RECORDING) RoseError else AmberWarning)
                    )
                    Spacer(modifier = Modifier.width(6.dp))
                    Text(
                        text = if (uiState.state == RecordingState.RECORDING) "RECORDING LIVE" else "PAUSED",
                        color = if (uiState.state == RecordingState.RECORDING) RoseError else AmberWarning,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold
                    )
                }

                Spacer(modifier = Modifier.height(32.dp))

                // Live Audio Waveform
                AudioWaveform(
                    isPlaying = uiState.state == RecordingState.RECORDING,
                    progress = 1.0f,
                    activeColor = IndigoLight,
                    barCount = 32,
                    modifier = Modifier.height(56.dp)
                )

                Spacer(modifier = Modifier.height(24.dp))

                // Live Streaming Transcript Box
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceDark),
                    border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .weight(1f)
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(16.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(
                                text = "Live Audio Capture",
                                style = MaterialTheme.typography.labelMedium,
                                color = TextSecondary,
                                fontWeight = FontWeight.Bold
                            )
                            Icon(
                                imageVector = Icons.Default.Hearing,
                                contentDescription = null,
                                tint = IndigoLight,
                                modifier = Modifier.size(16.dp)
                            )
                        }

                        Spacer(modifier = Modifier.height(10.dp))

                        if (uiState.errorMessage != null) {
                            Text(
                                text = uiState.errorMessage!!,
                                style = MaterialTheme.typography.bodyMedium,
                                color = RoseError,
                                lineHeight = 22.sp,
                                modifier = Modifier.testTag("record_error_text")
                            )
                        } else {
                            Text(
                                text = uiState.liveTranscript,
                                style = MaterialTheme.typography.bodyLarge,
                                color = TextPrimary,
                                lineHeight = 24.sp,
                                modifier = Modifier
                                    .fillMaxSize()
                                    .verticalScroll(rememberScrollState())
                                    .testTag("live_transcript_text")
                            )
                        }
                    }
                }

                Spacer(modifier = Modifier.height(32.dp))

                // Control Buttons
                Row(
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier.fillMaxWidth()
                ) {
                    // Cancel
                    IconButton(
                        onClick = {
                            viewModel.cancelRecording()
                            onNavigateBack()
                        },
                        colors = IconButtonDefaults.iconButtonColors(containerColor = SurfaceDark),
                        modifier = Modifier
                            .size(56.dp)
                            .testTag("cancel_recording_btn")
                    ) {
                        Icon(Icons.Default.DeleteOutline, contentDescription = "Cancel", tint = RoseError)
                    }

                    // Stop & Synthesize (Primary Action)
                    Button(
                        onClick = { viewModel.stopAndProcess() },
                        colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                        shape = CircleShape,
                        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 16.dp),
                        modifier = Modifier
                            .height(64.dp)
                            .testTag("stop_process_btn")
                    ) {
                        Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = Color.White)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "Synthesize",
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold,
                            color = Color.White
                        )
                    }

                    // Pause / Resume
                    IconButton(
                        onClick = {
                            if (uiState.state == RecordingState.RECORDING) {
                                viewModel.pauseRecording()
                            } else {
                                viewModel.resumeRecording()
                            }
                        },
                        colors = IconButtonDefaults.iconButtonColors(containerColor = SurfaceDark),
                        modifier = Modifier
                            .size(56.dp)
                            .testTag("pause_resume_recording_btn")
                    ) {
                        Icon(
                            imageVector = if (uiState.state == RecordingState.RECORDING) Icons.Default.Pause else Icons.Default.PlayArrow,
                            contentDescription = if (uiState.state == RecordingState.RECORDING) "Pause" else "Resume",
                            tint = IndigoLight
                        )
                    }
                }

                Spacer(modifier = Modifier.height(16.dp))
            }
        }
    }
}
