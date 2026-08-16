package com.example.ui.components

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.*
import com.example.ui.theme.*

@Composable
fun ConfidenceBadge(
    confidence: Double?,
    modifier: Modifier = Modifier
) {
    if (confidence == null) return
    val percent = (confidence * 100).toInt()
    val (color, container) = when {
        percent >= 90 -> Pair(EmeraldSuccess, EmeraldContainer)
        percent >= 75 -> Pair(SkyInfo, SurfaceCard)
        else -> Pair(AmberWarning, AmberContainer)
    }

    Surface(
        color = container.copy(alpha = 0.5f),
        shape = RoundedCornerShape(12.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.4f)),
        modifier = modifier
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = "AI Confidence",
                tint = color,
                modifier = Modifier.size(12.dp)
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = "$percent% match",
                color = color,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}

@Composable
fun PriorityBadge(priority: Priority?, modifier: Modifier = Modifier) {
    if (priority == null) return
    val (color, container) = when (priority) {
        Priority.HIGH -> Pair(RoseError, RoseContainer)
        Priority.MEDIUM -> Pair(AmberWarning, AmberContainer)
        Priority.LOW -> Pair(SkyInfo, SurfaceCard)
    }

    Surface(
        color = container.copy(alpha = 0.5f),
        shape = RoundedCornerShape(8.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, color.copy(alpha = 0.4f)),
        modifier = modifier
    ) {
        Text(
            text = priority.label,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
        )
    }
}

@Composable
fun ItemTypeBadge(type: ItemType, modifier: Modifier = Modifier) {
    val (color, icon) = when (type) {
        ItemType.ACTION_ITEM, ItemType.TASK -> Pair(EmeraldSuccess, Icons.Default.CheckCircle)
        ItemType.DECISION -> Pair(IndigoLight, Icons.Default.Gavel)
        ItemType.QUESTION -> Pair(AmberWarning, Icons.Default.HelpOutline)
        ItemType.IDEA -> Pair(PurpleGlow, Icons.Default.Lightbulb)
        ItemType.RISK, ItemType.PROBLEM -> Pair(RoseError, Icons.Default.Warning)
        ItemType.GOAL -> Pair(SkyInfo, Icons.Default.Flag)
        else -> Pair(TextSecondary, Icons.Default.Notes)
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .clip(RoundedCornerShape(6.dp))
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 2.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = type.label,
            tint = color,
            modifier = Modifier.size(12.dp)
        )
        Spacer(modifier = Modifier.width(4.dp))
        Text(
            text = type.label,
            color = color,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium
        )
    }
}

@Composable
fun TagChip(
    tag: String,
    selected: Boolean = false,
    onClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    Surface(
        color = if (selected) IndigoPrimary else SurfaceCard,
        shape = RoundedCornerShape(16.dp),
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (selected) IndigoLight else SurfaceBorder
        ),
        modifier = modifier.then(if (onClick != null) Modifier.clickable { onClick() } else Modifier)
    ) {
        Text(
            text = "#$tag",
            color = if (selected) Color.White else TextSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp)
        )
    }
}

@Composable
fun AudioWaveform(
    isPlaying: Boolean,
    progress: Float = 0f,
    modifier: Modifier = Modifier,
    barCount: Int = 28,
    activeColor: Color = IndigoLight,
    inactiveColor: Color = SurfaceBorder
) {
    val infiniteTransition = rememberInfiniteTransition(label = "waveform")
    val animatedPhase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 6.28f,
        animationSpec = infiniteRepeatable(
            animation = tween(1500, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "phase"
    )

    Canvas(modifier = modifier.height(36.dp).fillMaxWidth()) {
        val barWidth = size.width / (barCount * 1.5f)
        val gap = barWidth * 0.5f

        for (i in 0 until barCount) {
            val ratio = i.toFloat() / barCount
            val phaseDouble = (if (isPlaying) animatedPhase.toDouble() else 0.0)
            val baseHeight = (Math.sin(i.toDouble() * 0.45 + phaseDouble).toFloat() * 0.4f + 0.6f) * (size.height * 0.8f)
            val barHeight = baseHeight.coerceIn(6f, size.height)

            val x = i * (barWidth + gap)
            val y = (size.height - barHeight) / 2f

            val color = if (ratio <= progress) activeColor else inactiveColor

            drawRoundRect(
                color = color,
                topLeft = Offset(x, y),
                size = Size(barWidth, barHeight),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(barWidth / 2, barWidth / 2)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionCard(
    session: Session,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)? = null,
    onToggleFavorite: () -> Unit,
    onTogglePin: (() -> Unit)? = null,
    onMoreClick: (() -> Unit)? = null,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(containerColor = SurfaceDark),
        border = androidx.compose.foundation.BorderStroke(
            1.dp,
            if (session.pinned) IndigoPrimary.copy(alpha = 0.6f) else SurfaceBorder.copy(alpha = 0.5f)
        ),
        shape = RoundedCornerShape(16.dp),
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
            .testTag("session_card_${session.id}")
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.weight(1f)) {
                    if (session.pinned) {
                        Icon(
                            imageVector = Icons.Default.PushPin,
                            contentDescription = "Pinned",
                            tint = IndigoLight,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(6.dp))
                    }
                    Text(
                        text = session.title ?: "Untitled Session",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = onToggleFavorite,
                        modifier = Modifier.size(32.dp).testTag("favorite_btn_${session.id}")
                    ) {
                        Icon(
                            imageVector = if (session.favorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                            contentDescription = "Favorite",
                            tint = if (session.favorite) AmberWarning else TextMuted,
                            modifier = Modifier.size(18.dp)
                        )
                    }

                    if (onMoreClick != null || onLongClick != null) {
                        IconButton(
                            onClick = { (onMoreClick ?: onLongClick)?.invoke() },
                            modifier = Modifier.size(32.dp).testTag("more_btn_${session.id}")
                        ) {
                            Icon(
                                imageVector = Icons.Default.MoreVert,
                                contentDescription = "More Options",
                                tint = TextMuted,
                                modifier = Modifier.size(18.dp)
                            )
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(6.dp))

            Text(
                text = session.summary ?: session.cleanedTranscript ?: "Processing knowledge...",
                style = MaterialTheme.typography.bodyMedium,
                color = TextSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis
            )

            Spacer(modifier = Modifier.height(12.dp))

            // Topics and Item badges preview
            val allItems = session.topics.flatMap { it.items }
            val taskCount = allItems.count { it.type == ItemType.ACTION_ITEM || it.type == ItemType.TASK }
            val decisionCount = allItems.count { it.type == ItemType.DECISION }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                if (taskCount > 0) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(EmeraldContainer.copy(alpha = 0.4f))
                            .padding(horizontal = 6.dp, vertical = 3.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.CheckCircle,
                            contentDescription = null,
                            tint = EmeraldSuccess,
                            modifier = Modifier.size(12.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("$taskCount tasks", color = EmeraldSuccess, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                    }
                }

                if (decisionCount > 0) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(SurfaceCard)
                            .padding(horizontal = 6.dp, vertical = 3.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Gavel,
                            contentDescription = null,
                            tint = IndigoLight,
                            modifier = Modifier.size(12.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text("$decisionCount decisions", color = IndigoLight, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                    }
                }

                session.entities.firstOrNull()?.let { entity ->
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier
                            .clip(RoundedCornerShape(8.dp))
                            .background(SurfaceCard)
                            .padding(horizontal = 6.dp, vertical = 3.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Hub,
                            contentDescription = null,
                            tint = VioletAccent,
                            modifier = Modifier.size(12.dp)
                        )
                        Spacer(modifier = Modifier.width(4.dp))
                        Text(entity.name, color = TextSecondary, fontSize = 11.sp, maxLines = 1)
                    }
                }

                Spacer(modifier = Modifier.weight(1f))

                ConfidenceBadge(session.summaryConfidence)
            }

            Spacer(modifier = Modifier.height(10.dp))

            // Footer info
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = java.text.SimpleDateFormat("MMM dd, yyyy • HH:mm").format(java.util.Date(session.createdAt)),
                    fontSize = 11.sp,
                    color = TextMuted
                )

                if (session.durationSec != null && session.durationSec > 0) {
                    val mins = (session.durationSec / 60).toInt()
                    val secs = (session.durationSec % 60).toInt()
                    Text(
                        text = String.format("%02d:%02d", mins, secs),
                        fontSize = 11.sp,
                        color = TextMuted,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SwipeableSessionCard(
    session: Session,
    onClick: () -> Unit,
    onLongClick: () -> Unit,
    onToggleFavorite: () -> Unit,
    onTogglePin: () -> Unit,
    onSwipeArchive: () -> Unit,
    onSwipeDelete: () -> Unit,
    modifier: Modifier = Modifier
) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            when (value) {
                SwipeToDismissBoxValue.StartToEnd -> {
                    onSwipeArchive()
                    false
                }
                SwipeToDismissBoxValue.EndToStart -> {
                    onSwipeDelete()
                    false
                }
                SwipeToDismissBoxValue.Settled -> false
            }
        }
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = true,
        enableDismissFromEndToStart = true,
        backgroundContent = {
            val direction = dismissState.dismissDirection
            val isArchive = direction == SwipeToDismissBoxValue.StartToEnd
            val color = if (isArchive) {
                if (session.archived) EmeraldSuccess.copy(alpha = 0.85f) else IndigoPrimary.copy(alpha = 0.85f)
            } else {
                RoseError.copy(alpha = 0.85f)
            }

            val icon = if (isArchive) {
                if (session.archived) Icons.Default.Unarchive else Icons.Default.Archive
            } else {
                Icons.Default.Delete
            }

            val label = if (isArchive) {
                if (session.archived) "Unarchive" else "Archive"
            } else {
                "Delete / Discard"
            }

            val alignment = if (isArchive) Alignment.CenterStart else Alignment.CenterEnd

            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(RoundedCornerShape(16.dp))
                    .background(color)
                    .padding(horizontal = 24.dp),
                contentAlignment = alignment
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (isArchive) {
                        Icon(imageVector = icon, contentDescription = label, tint = Color.White)
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(text = label, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                    } else {
                        Text(text = label, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        Spacer(modifier = Modifier.width(8.dp))
                        Icon(imageVector = icon, contentDescription = label, tint = Color.White)
                    }
                }
            }
        },
        modifier = modifier
    ) {
        SessionCard(
            session = session,
            onClick = onClick,
            onLongClick = onLongClick,
            onToggleFavorite = onToggleFavorite,
            onTogglePin = onTogglePin,
            onMoreClick = onLongClick
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionActionsBottomSheet(
    session: Session,
    onDismiss: () -> Unit,
    onTogglePin: () -> Unit,
    onToggleFavorite: () -> Unit,
    onToggleArchive: () -> Unit,
    onRename: () -> Unit,
    onDuplicate: () -> Unit,
    onCopyContent: () -> Unit,
    onDelete: () -> Unit
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        containerColor = SurfaceDark,
        dragHandle = { BottomSheetDefaults.DragHandle(color = SurfaceBorder) }
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 8.dp)
        ) {
            // Header
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp)
            ) {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(IndigoPrimary.copy(alpha = 0.2f))
                ) {
                    Icon(
                        imageVector = if (!session.audioPath.isNullOrBlank()) Icons.Default.Mic else Icons.Default.Description,
                        contentDescription = null,
                        tint = IndigoLight,
                        modifier = Modifier.size(22.dp)
                    )
                }
                Spacer(modifier = Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = session.title ?: "Untitled Knowledge",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        color = TextPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                    Text(
                        text = "${java.text.SimpleDateFormat("MMM dd, yyyy • HH:mm").format(java.util.Date(session.createdAt))} • ${session.wordCount} words",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                        fontSize = 11.sp
                    )
                }
            }

            HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.6f))
            Spacer(modifier = Modifier.height(8.dp))

            // Action: Pin / Unpin
            ActionMenuItem(
                icon = Icons.Default.PushPin,
                iconTint = IndigoLight,
                title = if (session.pinned) "Unpin from Top" else "Pin to Top",
                onClick = {
                    onTogglePin()
                    onDismiss()
                },
                testTag = "action_pin_${session.id}"
            )

            // Action: Favorite / Unfavorite
            ActionMenuItem(
                icon = if (session.favorite) Icons.Filled.Star else Icons.Outlined.StarBorder,
                iconTint = AmberWarning,
                title = if (session.favorite) "Remove from Favorites" else "Add to Favorites",
                onClick = {
                    onToggleFavorite()
                    onDismiss()
                },
                testTag = "action_favorite_${session.id}"
            )

            // Action: Archive / Restore
            ActionMenuItem(
                icon = if (session.archived) Icons.Default.Unarchive else Icons.Default.Archive,
                iconTint = VioletAccent,
                title = if (session.archived) "Restore to Active" else "Archive Knowledge",
                onClick = {
                    onToggleArchive()
                    onDismiss()
                },
                testTag = "action_archive_${session.id}"
            )

            // Action: Rename
            ActionMenuItem(
                icon = Icons.Default.Edit,
                iconTint = SkyInfo,
                title = "Rename Session",
                onClick = {
                    onDismiss()
                    onRename()
                },
                testTag = "action_rename_${session.id}"
            )

            // Action: Duplicate
            ActionMenuItem(
                icon = Icons.Default.ContentCopy,
                iconTint = EmeraldSuccess,
                title = "Duplicate Entry",
                onClick = {
                    onDuplicate()
                    onDismiss()
                },
                testTag = "action_duplicate_${session.id}"
            )

            // Action: Copy Summary
            ActionMenuItem(
                icon = Icons.Default.CopyAll,
                iconTint = TextSecondary,
                title = "Copy Summary & Text",
                onClick = {
                    onCopyContent()
                    onDismiss()
                },
                testTag = "action_copy_${session.id}"
            )

            HorizontalDivider(color = SurfaceBorder.copy(alpha = 0.6f), modifier = Modifier.padding(vertical = 4.dp))

            // Action: Delete / Discard
            ActionMenuItem(
                icon = Icons.Default.Delete,
                iconTint = RoseError,
                title = "Delete / Discard",
                titleColor = RoseError,
                onClick = {
                    onDelete()
                    onDismiss()
                },
                testTag = "action_delete_${session.id}"
            )

            Spacer(modifier = Modifier.height(28.dp))
        }
    }
}

@Composable
private fun ActionMenuItem(
    icon: ImageVector,
    iconTint: Color,
    title: String,
    titleColor: Color = TextPrimary,
    onClick: () -> Unit,
    testTag: String
) {
    Surface(
        onClick = onClick,
        color = Color.Transparent,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().testTag(testTag)
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 12.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(20.dp)
            )
            Spacer(modifier = Modifier.width(16.dp))
            Text(
                text = title,
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                color = titleColor,
                fontSize = 14.sp
            )
        }
    }
}
