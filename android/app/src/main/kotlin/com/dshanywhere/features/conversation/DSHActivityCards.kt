package com.dshanywhere.features.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.BuildCircle
import androidx.compose.material.icons.filled.CallSplit
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.core.protocol.DSHCommandResult
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHModelChangeNotice
import com.dshanywhere.core.protocol.DSHModelSelection
import com.dshanywhere.core.protocol.DSHToolActivity
import com.dshanywhere.ui.theme.DSHColors
import java.time.Instant
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * Transcript activity cards ported from ToolActivityCard.swift and the private
 * `CommandResultCard` / `ModelChangeCard` structs of ConversationView.swift.
 */

// MARK: - Tool activity

/** SwiftUI: `ToolActivityCard`. */
@Composable
internal fun ToolActivityCard(tool: DSHToolActivity) {
    // SwiftUI: _isExpanded = State(initialValue: !Self.isShellTool(tool.name))
    var isExpanded by remember(tool.id) { mutableStateOf(!isShellTool(tool.name)) }
    val status = tool.status.lowercase()
    val isComplete = status in listOf("completed", "complete", "success", "succeeded")
    val detail = tool.detail
    val hasDetail = !detail.isNullOrBlank()

    // SwiftUI: .symbolEffect(.pulse, isActive: !isComplete)
    val pulse = rememberInfiniteTransition(label = "tool-pulse")
    val pulseAlpha by pulse.animateFloat(
        initialValue = 1f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(800), RepeatMode.Reverse),
        label = "tool-pulse-alpha",
    )
    val chevronRotation by animateFloatAsState(
        targetValue = if (isExpanded) 90f else 0f,
        animationSpec = tween(200), // .easeInOut(duration: 0.2)
        label = "tool-chevron",
    )

    Column(
        modifier = Modifier
            .fillMaxWidth()
            // SwiftUI: .background(Color.orange.opacity(0.08)), radius 12.
            .background(DSHColors.systemOrange().copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(
                    // SwiftUI: `guard hasDetail else { return }` in the button action.
                    if (hasDetail) Modifier.clickable { isExpanded = !isExpanded } else Modifier
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                // checkmark.circle.fill / gearshape.2.fill
                imageVector = if (isComplete) Icons.Filled.CheckCircle else Icons.Filled.BuildCircle,
                contentDescription = null,
                modifier = Modifier
                    .size(16.dp)
                    .alpha(if (isComplete) 1f else pulseAlpha),
                tint = if (isComplete) DSHColors.systemGreen() else DSHColors.systemOrange(),
            )
            Text(
                tool.name,
                style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold), // .subheadline.weight(.semibold)
                color = DSHColors.label(),
            )
            Spacer(Modifier.weight(1f))
            Text(
                dshCapitalized(tool.status), // .status.capitalized
                style = TextStyle(fontSize = 12.sp), // .caption
                color = DSHColors.secondaryLabel(),
            )
            if (hasDetail) {
                Icon(
                    Icons.AutoMirrored.Filled.KeyboardArrowRight, // chevron.right
                    contentDescription = null,
                    modifier = Modifier.size(12.dp).rotate(chevronRotation),
                    tint = DSHColors.secondaryLabel(),
                )
            }
        }

        AnimatedVisibility(
            visible = isExpanded && hasDetail,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it / 4 },
            exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it / 4 },
        ) {
            // SwiftUI: ScrollView(.horizontal) { Text(detail).font(.caption.monospaced())
            //          .fixedSize(horizontal: true, vertical: false) }
            detail?.let { body ->
                Box(Modifier.horizontalScroll(rememberScrollState())) {
                    Text(
                        body,
                        style = TextStyle(
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = DSHColors.secondaryLabel(),
                        ),
                    )
                }
            }
        }
    }
}

/** SwiftUI: `ToolActivityCard.isShellTool`. */
private fun isShellTool(name: String): Boolean {
    val value = name.lowercase()
    return listOf("bash", "shell", "terminal", "exec_command", "command").any { value.contains(it) }
}

// MARK: - Command result

/** SwiftUI: `CommandResultCard`. */
@Composable
internal fun CommandResultCard(result: DSHCommandResult) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            // SwiftUI: Color.secondary.opacity(0.1), radius 12.
            .background(
                DSHColors.secondaryLabel().copy(alpha = 0.1f),
                RoundedCornerShape(12.dp),
            )
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        // Label(caption.weight(.semibold)): checkmark.circle / questionmark.circle
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                imageVector = if (result.matched) Icons.Filled.CheckCircle else Icons.AutoMirrored.Filled.HelpOutline,
                contentDescription = null,
                modifier = Modifier.size(14.dp),
                tint = LocalContentColor.current,
            )
            Text(
                if (result.matched) {
                    DSHLocalization.string("Command completed")
                } else {
                    DSHLocalization.string("Command not found")
                },
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
            )
        }
        val text = result.text
        if (!text.isNullOrEmpty()) {
            Text(text, style = TextStyle(fontSize = 16.sp)) // .callout
        }
    }
}

// MARK: - Model change notice

/** SwiftUI: `ModelChangeCard` — inline system event for a model switch. */
@Composable
internal fun ModelChangeCard(notice: DSHModelChangeNotice) {
    val fromLabel = notice.previous?.let { compactSelectionName(it) } ?: "初始模型"
    val toLabel = compactSelectionName(notice.current)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // Color.secondary.opacity(0.08), radius 12 continuous.
            .background(
                DSHColors.secondaryLabel().copy(alpha = 0.08f),
                RoundedCornerShape(12.dp),
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Filled.CallSplit, // arrow.triangle.2.circlepath
            contentDescription = null,
            modifier = Modifier.size(12.dp),
            tint = DSHColors.secondaryLabel(),
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp), horizontalAlignment = Alignment.Start) {
            Text(
                "模型已切换", // Chinese literal in iOS source; unwrapped.
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold),
                color = DSHColors.secondaryLabel(),
            )
            Text(
                "$fromLabel → $toLabel",
                style = TextStyle(fontSize = 12.sp), // .caption
                color = DSHColors.label(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
        Text(
            formatNoticeTime(notice.timestamp),
            style = TextStyle(
                fontSize = 11.sp, // .caption2.monospacedDigit()
                fontFamily = FontFamily.Monospace,
                color = DSHColors.tertiaryLabel(),
            ),
        )
    }
}

private val noticeTimeFormatter: DateTimeFormatter =
    DateTimeFormatter.ofPattern("HH:mm", Locale.getDefault())

private fun formatNoticeTime(timestampMillis: Long): String =
    LocalDateTime
        .ofInstant(Instant.ofEpochMilli(timestampMillis), ZoneId.systemDefault())
        .format(noticeTimeFormatter)

/** SwiftUI: `ModelChangeCard.compact(_:)` — provider-aware abbreviations. */
private fun compactSelectionName(selection: DSHModelSelection): String {
    val value = selection.model
    val lowered = "${selection.provider}/$value".lowercase()
    if (lowered.contains("deepseek")) {
        if (lowered.contains("v4.1") && lowered.contains("flash")) return "DS V4.1F"
        if (lowered.contains("v4.1") && (lowered.contains("reason") || lowered.contains("r1"))) return "DS V4.1R"
        if (lowered.contains("v4.1")) return "DS V4.1"
    }
    if (lowered.contains("claude")) {
        if (lowered.contains("opus")) return "Claude Opus"
        if (lowered.contains("sonnet")) return "Claude Sonnet"
    }
    return value
}
