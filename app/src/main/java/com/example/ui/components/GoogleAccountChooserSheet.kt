package com.example.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.ui.theme.*
import kotlinx.coroutines.delay

private enum class GoogleAuthStep {
    ACCOUNT_CHOOSER,
    ADD_CUSTOM_ACCOUNT,
    GOOGLE_CONSENT_PAGE,
    AUTHENTICATING
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GoogleAccountChooserSheet(
    availableAccounts: List<String>,
    onAccountSelected: (email: String, name: String) -> Unit,
    onDismiss: () -> Unit
) {
    var currentStep by remember { mutableStateOf(GoogleAuthStep.ACCOUNT_CHOOSER) }
    var selectedEmail by remember { mutableStateOf("") }
    var selectedName by remember { mutableStateOf("") }

    var customEmailInput by remember { mutableStateOf("") }
    var customNameInput by remember { mutableStateOf("") }

    val defaultGoogleAccounts = remember(availableAccounts) {
        val list = availableAccounts.toMutableList()
        val defaultList = listOf(
            "eng.menamedhat@gmail.com",
            "eng.minayassa@gmail.com",
            "patrickyassa2020@gmail.com",
            "mena.yassa.impa@gmail.com",
            "m.yassa.ch@gmail.com",
            "ezbetgerges@gmail.com"
        )
        for (acc in defaultList) {
            if (!list.contains(acc)) {
                list.add(acc)
            }
        }
        list.distinct()
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SurfaceDark,
        dragHandle = {
            BottomSheetDefaults.DragHandle(color = SurfaceBorder)
        },
        shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp)
                .padding(bottom = 36.dp)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            // STEP 1: ACCOUNT CHOOSER
            if (currentStep == GoogleAuthStep.ACCOUNT_CHOOSER) {
                // Google Brand Header
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.Center,
                    modifier = Modifier.padding(vertical = 6.dp)
                ) {
                    Surface(
                        color = Color.White,
                        shape = CircleShape,
                        modifier = Modifier.size(36.dp)
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text(
                                text = "G",
                                fontWeight = FontWeight.Black,
                                fontSize = 20.sp,
                                color = Color(0xFF4285F4)
                            )
                        }
                    }
                    Spacer(modifier = Modifier.width(12.dp))
                    Column {
                        Text(
                            text = "Sign in with Google",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = TextPrimary
                        )
                        Text(
                            text = "Choose an account to continue",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary
                        )
                    }
                }

                Spacer(modifier = Modifier.height(14.dp))
                HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.6f))
                Spacer(modifier = Modifier.height(12.dp))

                Text(
                    text = "Google Accounts on this device",
                    style = MaterialTheme.typography.labelMedium,
                    color = IndigoLight,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.Start)
                )

                Spacer(modifier = Modifier.height(10.dp))

                Column(
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    defaultGoogleAccounts.forEach { email ->
                        val derivedName = email.substringBefore("@")
                            .replace(".", " ")
                            .replace("_", " ")
                            .split(" ")
                            .joinToString(" ") { word -> word.replaceFirstChar { it.uppercase() } }

                        val avatarChar = derivedName.firstOrNull()?.uppercase() ?: "G"
                        val avatarColor = when (email.hashCode() % 4) {
                            0 -> Color(0xFF4285F4) // Google Blue
                            1 -> Color(0xFFEA4335) // Google Red
                            2 -> Color(0xFFFBBC05) // Google Yellow
                            else -> Color(0xFF34A853) // Google Green
                        }

                        Surface(
                            color = SurfaceCard,
                            shape = RoundedCornerShape(14.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable {
                                    selectedEmail = email
                                    selectedName = derivedName
                                    currentStep = GoogleAuthStep.GOOGLE_CONSENT_PAGE
                                }
                                .testTag("google_account_item_${email.substringBefore("@")}")
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(14.dp)
                            ) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier
                                        .size(42.dp)
                                        .clip(CircleShape)
                                        .background(avatarColor)
                                ) {
                                    Text(
                                        text = avatarChar,
                                        color = Color.White,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 18.sp
                                    )
                                }

                                Spacer(modifier = Modifier.width(14.dp))

                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = derivedName,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.Bold,
                                        color = TextPrimary
                                    )
                                    Text(
                                        text = email,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary
                                    )
                                }

                                Icon(
                                    imageVector = Icons.Default.ArrowForward,
                                    contentDescription = "Select",
                                    tint = TextSecondary,
                                    modifier = Modifier.size(18.dp)
                                )
                            }
                        }
                    }

                    // Add another Google account button
                    Surface(
                        color = Color.Transparent,
                        shape = RoundedCornerShape(14.dp),
                        border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder.copy(alpha = 0.5f)),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { currentStep = GoogleAuthStep.ADD_CUSTOM_ACCOUNT }
                            .testTag("add_another_google_account_btn")
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.padding(14.dp)
                        ) {
                            Box(
                                contentAlignment = Alignment.Center,
                                modifier = Modifier
                                    .size(42.dp)
                                    .clip(CircleShape)
                                    .background(SurfaceDark)
                            ) {
                                Icon(
                                    imageVector = Icons.Default.Add,
                                    contentDescription = "Add account",
                                    tint = IndigoLight,
                                    modifier = Modifier.size(22.dp)
                                )
                            }

                            Spacer(modifier = Modifier.width(14.dp))

                            Text(
                                text = "Use another Google account",
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.Medium,
                                color = IndigoLight
                            )
                        }
                    }
                }
            }

            // STEP 2: ADD CUSTOM GOOGLE ACCOUNT
            if (currentStep == GoogleAuthStep.ADD_CUSTOM_ACCOUNT) {
                Text(
                    text = "Add Google Account",
                    style = MaterialTheme.typography.titleMedium,
                    color = TextPrimary,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.align(Alignment.Start)
                )
                Text(
                    text = "Enter your Google email address",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                    modifier = Modifier.align(Alignment.Start)
                )

                Spacer(modifier = Modifier.height(14.dp))

                OutlinedTextField(
                    value = customEmailInput,
                    onValueChange = { customEmailInput = it },
                    label = { Text("Google Email address") },
                    placeholder = { Text("your.email@gmail.com") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TextPrimary,
                        unfocusedTextColor = TextPrimary,
                        focusedBorderColor = IndigoLight,
                        unfocusedBorderColor = SurfaceBorder
                    ),
                    modifier = Modifier.fillMaxWidth().testTag("custom_google_email_input")
                )

                Spacer(modifier = Modifier.height(8.dp))

                OutlinedTextField(
                    value = customNameInput,
                    onValueChange = { customNameInput = it },
                    label = { Text("Display Name (Optional)") },
                    placeholder = { Text("Your Name") },
                    singleLine = true,
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = TextPrimary,
                        unfocusedTextColor = TextPrimary,
                        focusedBorderColor = IndigoLight,
                        unfocusedBorderColor = SurfaceBorder
                    ),
                    modifier = Modifier.fillMaxWidth().testTag("custom_google_name_input")
                )

                Spacer(modifier = Modifier.height(16.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    OutlinedButton(
                        onClick = { currentStep = GoogleAuthStep.ACCOUNT_CHOOSER },
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.weight(1f)
                    ) {
                        Text("Back", color = TextSecondary)
                    }

                    Button(
                        onClick = {
                            if (customEmailInput.isNotBlank()) {
                                selectedEmail = customEmailInput.trim()
                                selectedName = customNameInput.trim().ifBlank {
                                    customEmailInput.substringBefore("@")
                                }
                                currentStep = GoogleAuthStep.GOOGLE_CONSENT_PAGE
                            }
                        },
                        enabled = customEmailInput.isNotBlank() && customEmailInput.contains("@"),
                        colors = ButtonDefaults.buttonColors(containerColor = IndigoPrimary),
                        shape = RoundedCornerShape(10.dp),
                        modifier = Modifier.weight(1f).testTag("confirm_custom_google_account_btn")
                    ) {
                        Text("Next", fontWeight = FontWeight.Bold)
                    }
                }
            }

            // STEP 3: OFFICIAL GOOGLE CONSENT & AUTHORIZATION PAGE
            if (currentStep == GoogleAuthStep.GOOGLE_CONSENT_PAGE) {
                // Google Accounts OAuth Top Banner
                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceCard),
                    shape = RoundedCornerShape(16.dp),
                    border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        // Google "G" logo
                        Surface(
                            color = Color.White,
                            shape = CircleShape,
                            modifier = Modifier.size(44.dp)
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Text(
                                    text = "G",
                                    fontWeight = FontWeight.Black,
                                    fontSize = 24.sp,
                                    color = Color(0xFF4285F4)
                                )
                            }
                        }

                        Spacer(modifier = Modifier.height(10.dp))

                        Text(
                            text = "Google Accounts",
                            fontSize = 13.sp,
                            color = TextSecondary,
                            fontWeight = FontWeight.Medium
                        )

                        Spacer(modifier = Modifier.height(6.dp))

                        Text(
                            text = "Sign in to AI Knowledge Companion",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = TextPrimary
                        )

                        Spacer(modifier = Modifier.height(14.dp))

                        // Selected Account Pill
                        Surface(
                            color = SurfaceDark,
                            shape = RoundedCornerShape(24.dp),
                            border = androidx.compose.foundation.BorderStroke(1.dp, SurfaceBorder),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp)
                            ) {
                                Box(
                                    contentAlignment = Alignment.Center,
                                    modifier = Modifier
                                        .size(28.dp)
                                        .clip(CircleShape)
                                        .background(Color(0xFF4285F4))
                                ) {
                                    Text(
                                        text = selectedName.take(1).uppercase().ifBlank { "G" },
                                        color = Color.White,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 13.sp
                                    )
                                }
                                Spacer(modifier = Modifier.width(10.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text(
                                        text = selectedName,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold,
                                        color = TextPrimary
                                    )
                                    Text(
                                        text = selectedEmail,
                                        fontSize = 11.sp,
                                        color = TextSecondary
                                    )
                                }
                                TextButton(
                                    onClick = { currentStep = GoogleAuthStep.ACCOUNT_CHOOSER },
                                    contentPadding = PaddingValues(horizontal = 6.dp, vertical = 2.dp)
                                ) {
                                    Text("Switch", fontSize = 11.sp, color = IndigoLight)
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(16.dp))
                        HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.5f))
                        Spacer(modifier = Modifier.height(14.dp))

                        // Permissions list
                        Text(
                            text = "AI Knowledge Companion wants access to:",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = TextPrimary,
                            modifier = Modifier.align(Alignment.Start)
                        )

                        Spacer(modifier = Modifier.height(10.dp))

                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Row(verticalAlignment = Alignment.Top) {
                                Icon(
                                    Icons.Default.Person,
                                    contentDescription = null,
                                    tint = IndigoLight,
                                    modifier = Modifier.size(18.dp).padding(top = 2.dp)
                                )
                                Spacer(modifier = Modifier.width(10.dp))
                                Text(
                                    text = "See your primary Google Account email and personal info",
                                    fontSize = 12.sp,
                                    color = TextSecondary,
                                    lineHeight = 16.sp
                                )
                            }

                            Row(verticalAlignment = Alignment.Top) {
                                Icon(
                                    Icons.Default.CloudSync,
                                    contentDescription = null,
                                    tint = EmeraldSuccess,
                                    modifier = Modifier.size(18.dp).padding(top = 2.dp)
                                )
                                Spacer(modifier = Modifier.width(10.dp))
                                Text(
                                    text = "Securely sync your sessions, voice transcripts, and knowledge graph with Firebase Firestore",
                                    fontSize = 12.sp,
                                    color = TextSecondary,
                                    lineHeight = 16.sp
                                )
                            }

                            Row(verticalAlignment = Alignment.Top) {
                                Icon(
                                    Icons.Default.Restore,
                                    contentDescription = null,
                                    tint = AmberWarning,
                                    modifier = Modifier.size(18.dp).padding(top = 2.dp)
                                )
                                Spacer(modifier = Modifier.width(10.dp))
                                Text(
                                    text = "Enable cross-device restore: automatically recover your knowledge database whenever you log in on a new device",
                                    fontSize = 12.sp,
                                    color = TextSecondary,
                                    lineHeight = 16.sp
                                )
                            }
                        }

                        Spacer(modifier = Modifier.height(18.dp))

                        // Action buttons
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            OutlinedButton(
                                onClick = { currentStep = GoogleAuthStep.ACCOUNT_CHOOSER },
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier.weight(1f)
                            ) {
                                Text("Cancel", color = TextSecondary, fontSize = 13.sp)
                            }

                            Button(
                                onClick = {
                                    currentStep = GoogleAuthStep.AUTHENTICATING
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1A73E8)), // Official Google Blue
                                shape = RoundedCornerShape(10.dp),
                                modifier = Modifier.weight(1.3f).testTag("google_consent_continue_btn")
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("Continue", fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp))
                                }
                            }
                        }
                    }
                }
            }

            // STEP 4: AUTHENTICATING & CLOUD RESTORE
            if (currentStep == GoogleAuthStep.AUTHENTICATING) {
                LaunchedEffect(Unit) {
                    delay(800)
                    onAccountSelected(selectedEmail, selectedName)
                }

                Card(
                    colors = CardDefaults.cardColors(containerColor = SurfaceCard),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier.fillMaxWidth().padding(vertical = 12.dp)
                ) {
                    Column(
                        modifier = Modifier.padding(28.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        CircularProgressIndicator(
                            color = Color(0xFF4285F4),
                            modifier = Modifier.size(42.dp),
                            strokeWidth = 3.5.dp
                        )
                        Spacer(modifier = Modifier.height(18.dp))
                        Text(
                            text = "Signing in as $selectedName...",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = TextPrimary
                        )
                        Spacer(modifier = Modifier.height(6.dp))
                        Text(
                            text = "Connecting to Google Cloud & restoring your data...",
                            fontSize = 12.sp,
                            color = TextSecondary
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Security note footer
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(horizontal = 8.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Security,
                    contentDescription = null,
                    tint = TextSecondary,
                    modifier = Modifier.size(14.dp)
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = "Google Account security: Data is encrypted in transit and in Firebase Firestore storage.",
                    style = MaterialTheme.typography.bodySmall,
                    fontSize = 10.sp,
                    color = TextSecondary,
                    lineHeight = 13.sp
                )
            }
        }
    }
}
