package com.dshanywhere.features.conversation

import android.graphics.BitmapFactory
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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.core.protocol.DSHChatMessage
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHMessageAttachment
import com.dshanywhere.core.protocol.DSHMessageRole
import com.dshanywhere.core.protocol.DSHSessionUsage
import com.dshanywhere.core.protocol.DSHTranscriptBlock
import com.dshanywhere.ui.theme.DSHColors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Message rendering ported from ConversationView.swift: `MessageBubble`,
 * `MessageAttachmentsView`, `MessageAttachmentPreview`, `AssistantTurnView`
 * and `ThinkingDisclosure`.
 */

/** SwiftUI: `Color.secondary.opacity(0.12)` assistant bubble fill. */
@Composable
private fun bubbleGray(): Color = DSHColors.secondaryLabel().copy(alpha = 0.12f)

/** SwiftUI: `AssistantTurnView` — every answer of a turn, then one merged disclosure. */
@Composable
internal fun AssistantTurnView(sessionID: String, block: DSHTranscriptBlock, streaming: Boolean) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        block.visibleMessages.forEach { message ->
            MessageBubble(sessionID = sessionID, message = message)
        }
        val timeline = block.taskTimeline
        if (timeline != null) {
            val details = buildList {
                if (timeline.reasoning.isNotBlank()) add(timeline.reasoning)
                timeline.tools.forEach { tool ->
                    val detail = tool.arguments ?: tool.detail
                    add(if (detail.isNullOrBlank()) tool.name else "${tool.name}\n$detail")
                }
            }.joinToString("\n\n")
            ThinkingDisclosure(
                text = details,
                title = taskDurationLabel(
                    timeline.duration(if (streaming) System.currentTimeMillis() else null),
                ),
                streaming = streaming,
            )
        }
    }
}

/** SwiftUI: `MessageBubble`. */
@Composable
internal fun MessageBubble(sessionID: String, message: DSHChatMessage) {
    val model = LocalAppModel.current
    var showDeleteConfirmation by remember { mutableStateOf(false) }
    var didCopy by remember { mutableStateOf(false) }
    val copy = rememberCopyToClipboard()
    val scope = rememberCoroutineScope()
    val isUser = message.role == DSHMessageRole.user
    val accent = MaterialTheme.colorScheme.primary

    // SwiftUI: VStack(alignment: .leading, spacing: 5)
    Column(verticalArrangement = Arrangement.spacedBy(5.dp), horizontalAlignment = Alignment.Start) {
        Row(Modifier.fillMaxWidth()) {
            // HStack { if user Spacer(minLength: 36); bubble; if !user Spacer(minLength: 36) }
            if (isUser) Spacer(Modifier.weight(1f).widthIn(min = 36.dp))
            Box(
                modifier = Modifier
                    .background(
                        if (isUser) accent else Color.Transparent,
                        RoundedCornerShape(16.dp),
                    )
                    .clip(RoundedCornerShape(16.dp))
                    .padding(
                        horizontal = if (isUser) 14.dp else 0.dp,
                        vertical = if (isUser) 10.dp else 2.dp,
                    ),
            ) {
                // .foregroundStyle(user ? .white : .primary)
                CompositionLocalProvider(
                    LocalContentColor provides if (isUser) Color.White else DSHColors.label(),
                ) {
                    // messageContent: VStack(alignment: .leading, spacing: 8)
                    Column(
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                        horizontalAlignment = Alignment.Start,
                    ) {
                        if (message.attachments.isNotEmpty()) {
                            MessageAttachmentsView(attachments = message.attachments)
                        }
                        if (message.markdown.isNotEmpty()) {
                            // Long-press to select and copy a reply: the whole
                            // transcript is wrapped in a selectionContainer()
                            // (see ConversationScreen).
                            MarkdownBlockText(text = message.markdown)
                        }
                    }
                }
            }
            if (!isUser) Spacer(Modifier.weight(1f).widthIn(min = 36.dp))
        }

        // Action row: copy + delete, .font(.caption) .foregroundStyle(.secondary).
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (isUser) Spacer(Modifier.weight(1f).widthIn(min = 36.dp))
            Box(
                modifier = Modifier
                    .width(28.dp)
                    .height(24.dp)
                    .clickable {
                        // copyMessage(): markdown plus "📎 name" attachment lines.
                        val attachmentLines = message.attachments.map { "📎 ${it.name}" }
                        val value = (listOf(message.markdown) + attachmentLines)
                            .filter { it.isNotEmpty() }
                            .joinToString(separator = if (message.markdown.isEmpty()) "\n" else "\n\n")
                        copy(value)
                        didCopy = true
                        scope.launch {
                            delay(1_200)
                            didCopy = false
                        }
                    }
                    .semantics {
                        contentDescription = if (didCopy) {
                            DSHLocalization.string("Copied")
                        } else {
                            DSHLocalization.string("Copy")
                        }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    // checkmark / doc.on.doc
                    imageVector = if (didCopy) Icons.Filled.Check else Icons.Filled.ContentCopy,
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = DSHColors.secondaryLabel(),
                )
            }
            Box(
                modifier = Modifier
                    .width(28.dp)
                    .height(24.dp)
                    .clickable { showDeleteConfirmation = true }
                    .semantics { contentDescription = DSHLocalization.string("Delete") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.Delete, // trash
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                    tint = DSHColors.secondaryLabel(),
                )
            }
            if (!isUser) Spacer(Modifier.weight(1f).widthIn(min = 36.dp))
        }
    }

    // SwiftUI: confirmationDialog("Delete this message?", titleVisibility: .visible)
    if (showDeleteConfirmation) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirmation = false },
            title = { Text(DSHLocalization.string("Delete this message?")) },
            text = {
                Text(
                    DSHLocalization.string(
                        "This removes the message from this iPhone only. The original Harness history on your Mac is unchanged.",
                    ),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showDeleteConfirmation = false
                        model.hideMessage(message.id, sessionID)
                    },
                ) {
                    Text(DSHLocalization.string("Delete"), color = DSHColors.systemRed())
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirmation = false }) {
                    Text(DSHLocalization.string("Cancel"))
                }
            },
        )
    }
}

/** SwiftUI: `MessageAttachmentsView` — VStack(spacing: 6) capped at 280pt. */
@Composable
private fun MessageAttachmentsView(attachments: List<DSHMessageAttachment>) {
    Column(
        modifier = Modifier.widthIn(max = 280.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        attachments.forEach { attachment ->
            MessageAttachmentPreview(attachment = attachment)
        }
    }
}

/** SwiftUI: `MessageAttachmentPreview`. */
@Composable
private fun MessageAttachmentPreview(attachment: DSHMessageAttachment) {
    val model = LocalAppModel.current
    // SwiftUI: .task(id: attachment.id) { data = model.attachmentData(for: attachment) }
    var data by remember(attachment.id) { mutableStateOf<ByteArray?>(null) }
    LaunchedEffect(attachment.id) {
        data = if (attachment.isImage) model.attachmentData(attachment) else null
    }
    val bitmap = remember(data) {
        data?.let { bytes ->
            runCatching { BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
        }
    }
    if (attachment.isImage && bitmap != null) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp), horizontalAlignment = Alignment.Start) {
            androidx.compose.foundation.Image(
                bitmap = bitmap.asImageBitmap(),
                contentDescription = attachment.name,
                modifier = Modifier
                    .widthIn(max = 260.dp)
                    .heightIn(max = 190.dp)
                    .clip(RoundedCornerShape(10.dp)),
                contentScale = ContentScale.Fit,
            )
            Text(
                attachment.name,
                style = TextStyle(fontSize = 11.sp), // .caption2
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    } else {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(
                    // Color.primary.opacity(0.08), radius 8.
                    DSHColors.label().copy(alpha = 0.08f),
                    RoundedCornerShape(8.dp),
                )
                .padding(horizontal = 9.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                // photo / paperclip
                if (attachment.isImage) Icons.Filled.PhotoCamera else Icons.Filled.AttachFile,
                contentDescription = null,
                modifier = Modifier.size(14.dp), // .caption semibold
                tint = LocalContentColor.current,
            )
            Text(
                attachment.name,
                style = TextStyle(fontSize = 12.sp), // .caption
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.weight(1f).widthIn(min = 0.dp))
        }
    }
}

/**
 * SwiftUI: `ThinkingDisclosure` — one subdued row per turn, collapsed by
 * default; expansion is capped at 240pt and scrolls.
 *
 * `streaming` drives a pulsing dot: the iOS view has no dedicated indicator
 * (its text simply grows with each delta), the Android port adds the pulse so
 * a collapsed section still shows work happening.
 */
@Composable
private fun ThinkingDisclosure(
    text: String,
    title: String,
    streaming: Boolean,
) {
    var isExpanded by remember(text.isNotEmpty()) { mutableStateOf(false) }
    val caption2 = TextStyle(fontSize = 11.sp) // .caption2
    Column(
        modifier = Modifier.widthIn(max = 320.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable { isExpanded = !isExpanded }
                .semantics {
                    contentDescription = if (isExpanded) {
                        DSHLocalization.string("Hide reasoning")
                    } else {
                        DSHLocalization.string("Show reasoning")
                    }
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Icon(
                Icons.Filled.Psychology, // brain
                contentDescription = null,
                modifier = Modifier.size(12.dp),
                tint = DSHColors.secondaryLabel(),
            )
            Text(
                title,
                style = caption2,
                color = DSHColors.secondaryLabel(),
            )
            if (streaming && !isExpanded) {
                // Streaming indicator: small pulsing accent dot.
                val pulse = rememberInfiniteTransition(label = "thinking-pulse")
                val alpha by pulse.animateFloat(
                    initialValue = 1f,
                    targetValue = 0.2f,
                    animationSpec = infiniteRepeatable(tween(600), RepeatMode.Reverse),
                    label = "thinking-pulse-alpha",
                )
                Box(
                    Modifier
                        .size(5.dp)
                        .alpha(alpha)
                        .background(MaterialTheme.colorScheme.primary, CircleShape),
                )
            }
            val rotation by animateFloatAsState(
                targetValue = if (isExpanded) 90f else 0f,
                animationSpec = tween(200),
                label = "thinking-chevron",
            )
            Icon(
                Icons.AutoMirrored.Filled.KeyboardArrowRight, // chevron.right
                contentDescription = null,
                modifier = Modifier.size(11.dp).rotate(rotation),
                tint = DSHColors.secondaryLabel(),
            )
            Spacer(Modifier.weight(1f).widthIn(min = 0.dp))
        }

        AnimatedVisibility(
            visible = isExpanded,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it / 4 },
            exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it / 4 },
        ) {
            // Capped height + scroll so a long chain-of-thought never pushes the
            // answers off screen (SwiftUI comment).
            Box(
                Modifier
                    .fillMaxWidth()
                    .heightIn(max = 240.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(bubbleGraySoft())
                    .padding(10.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                Text(
                    text,
                    style = TextStyle(fontSize = 12.sp), // .caption
                    color = DSHColors.secondaryLabel(),
                )
            }
        }
    }
}

private fun taskDurationLabel(duration: Pair<Int, Boolean>?): String {
    if (duration == null) return DSHLocalization.string("Thinking")
    val (seconds, estimated) = duration
    val value = when {
        seconds >= 3_600 -> "${seconds / 3_600} hr ${(seconds % 3_600) / 60} min"
        seconds >= 60 -> "${seconds / 60} min ${seconds % 60} sec"
        else -> "$seconds sec"
    }
    return DSHLocalization.format("Took %@", "${if (estimated) "≈" else ""}$value")
}

/** SwiftUI: `Color.secondary.opacity(0.08)`. */
@Composable
private fun bubbleGraySoft(): Color = DSHColors.secondaryLabel().copy(alpha = 0.08f)

/** SwiftUI: `turnStats` — total in/out tokens for the turn, or empty. */
private fun turnStats(usage: DSHSessionUsage): String {
    val input = usage.inputTokens ?: 0.0
    val output = usage.outputTokens ?: 0.0
    if (input == 0.0 && output == 0.0) return ""
    return "${dshCompactNumber(input + output)} tok"
}
