package com.example.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.rememberTransformableState
import androidx.compose.foundation.gestures.transformable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.example.data.model.*
import com.example.ui.theme.*
import kotlin.math.*

@Composable
fun KnowledgeGraphCanvas(
    entities: List<GraphEntity>,
    relationships: List<GraphRelation>,
    selectedEntity: GraphEntity?,
    onSelectEntity: (GraphEntity?) -> Unit,
    modifier: Modifier = Modifier
) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }

    val transformState = rememberTransformableState { zoomChange, offsetChange, _ ->
        scale = (scale * zoomChange).coerceIn(0.5f, 3.0f)
        offset += offsetChange
    }

    // Compute positions for entities in a pleasant circle / graph arrangement
    val nodePositions = remember(entities) {
        val positions = mutableMapOf<String, Offset>()
        val count = entities.size
        val radius = if (count > 8) 280f else 180f
        val center = Offset(500f, 450f)

        entities.forEachIndexed { index, entity ->
            if (count == 1) {
                positions[entity.id] = center
            } else {
                val angle = (2.0 * PI * index / count).toFloat()
                val x = center.x + radius * cos(angle)
                val y = center.y + radius * sin(angle)
                positions[entity.id] = Offset(x, y)
            }
        }
        positions
    }

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(DeepSlate)
            .transformable(state = transformState)
            .pointerInput(entities, scale, offset) {
                detectTapGestures { tapOffset ->
                    val transformedTap = (tapOffset - offset) / scale
                    // Check if tapped near any node
                    var tapped: GraphEntity? = null
                    for (entity in entities) {
                        val pos = nodePositions[entity.id] ?: continue
                        val distance = (pos - transformedTap).getDistance()
                        if (distance <= 45f) {
                            tapped = entity
                            break
                        }
                    }
                    onSelectEntity(tapped)
                }
            }
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val canvasCenter = Offset(size.width / 2f, size.height / 2f)

            // Draw grid dots in background
            val gridSpacing = 40f * scale
            val startX = (offset.x % gridSpacing)
            val startY = (offset.y % gridSpacing)
            var x = startX
            while (x < size.width) {
                var y = startY
                while (y < size.height) {
                    drawCircle(SurfaceBorder.copy(alpha = 0.25f), radius = 1.5f * scale, center = Offset(x, y))
                    y += gridSpacing
                }
                x += gridSpacing
            }

            // Draw Edges / Relationships
            relationships.forEach { rel ->
                val srcPos = nodePositions[rel.sourceId]
                val tgtPos = nodePositions[rel.targetId]

                if (srcPos != null && tgtPos != null) {
                    val p1 = srcPos * scale + offset
                    val p2 = tgtPos * scale + offset

                    val isConnectedToSelected = selectedEntity != null &&
                            (selectedEntity.id == rel.sourceId || selectedEntity.id == rel.targetId)

                    val edgeColor = if (isConnectedToSelected) IndigoLight else SurfaceBorder.copy(alpha = 0.7f)
                    val strokeWidth = if (isConnectedToSelected) 3.5f * scale else 2f * scale

                    drawLine(
                        color = edgeColor,
                        start = p1,
                        end = p2,
                        strokeWidth = strokeWidth
                    )

                    // Draw relationship label in the center
                    val mid = (p1 + p2) / 2f
                    val paint = android.graphics.Paint().apply {
                        color = android.graphics.Color.argb(200, 148, 163, 184)
                        textSize = (11f * scale).coerceAtLeast(14f)
                        textAlign = android.graphics.Paint.Align.CENTER
                        isAntiAlias = true
                    }
                    drawContext.canvas.nativeCanvas.drawText(
                        rel.type.label,
                        mid.x,
                        mid.y - (4f * scale),
                        paint
                    )
                }
            }

            // Draw Nodes / Entities
            entities.forEach { entity ->
                val basePos = nodePositions[entity.id] ?: Offset(500f, 450f)
                val nodePos = basePos * scale + offset
                val isSelected = selectedEntity?.id == entity.id

                val (nodeColor, ringColor) = when (entity.type) {
                    EntityType.PERSON -> Pair(SkyInfo, SkyInfo.copy(alpha = 0.3f))
                    EntityType.PROJECT -> Pair(IndigoLight, IndigoPrimary.copy(alpha = 0.3f))
                    EntityType.CONCEPT -> Pair(VioletAccent, PurpleGlow.copy(alpha = 0.3f))
                    EntityType.TOOL -> Pair(EmeraldSuccess, EmeraldContainer.copy(alpha = 0.3f))
                    EntityType.ORGANIZATION -> Pair(AmberWarning, AmberContainer.copy(alpha = 0.3f))
                    else -> Pair(TextSecondary, SurfaceBorder)
                }

                val nodeRadius = (if (isSelected) 30f else 24f) * scale

                // Outer glow ring
                drawCircle(
                    color = if (isSelected) IndigoLight.copy(alpha = 0.5f) else ringColor,
                    radius = nodeRadius + (8f * scale),
                    center = nodePos
                )

                // Main Node circle
                drawCircle(
                    color = SurfaceDark,
                    radius = nodeRadius,
                    center = nodePos
                )
                drawCircle(
                    color = nodeColor,
                    radius = nodeRadius,
                    center = nodePos,
                    style = Stroke(width = 3f * scale)
                )

                // Label
                val paint = android.graphics.Paint().apply {
                    color = if (isSelected) android.graphics.Color.WHITE else android.graphics.Color.argb(240, 248, 250, 252)
                    textSize = (13f * scale).coerceAtLeast(16f)
                    textAlign = android.graphics.Paint.Align.CENTER
                    isFakeBoldText = isSelected
                    isAntiAlias = true
                }
                drawContext.canvas.nativeCanvas.drawText(
                    entity.name,
                    nodePos.x,
                    nodePos.y + nodeRadius + (16f * scale),
                    paint
                )
            }
        }

        // Overlay zoom & reset controls
        Row(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            IconButton(
                onClick = { scale = (scale + 0.25f).coerceAtMost(3.0f) },
                colors = IconButtonDefaults.iconButtonColors(containerColor = SurfaceDark)
            ) {
                Icon(Icons.Default.Add, contentDescription = "Zoom In", tint = TextPrimary)
            }
            IconButton(
                onClick = { scale = (scale - 0.25f).coerceAtLeast(0.5f) },
                colors = IconButtonDefaults.iconButtonColors(containerColor = SurfaceDark)
            ) {
                Icon(Icons.Default.Remove, contentDescription = "Zoom Out", tint = TextPrimary)
            }
            IconButton(
                onClick = { scale = 1f; offset = Offset.Zero },
                colors = IconButtonDefaults.iconButtonColors(containerColor = SurfaceDark)
            ) {
                Icon(Icons.Default.CenterFocusStrong, contentDescription = "Reset View", tint = TextPrimary)
            }
        }
    }
}
