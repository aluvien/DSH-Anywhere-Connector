package com.dshanywhere.features.conversation

import android.graphics.BitmapFactory
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.CallSplit
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.DataUsage
import androidx.compose.material.icons.filled.Equalizer
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.SaveAlt
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.app.DSHDeviceStatus
import com.dshanywhere.app.DSHStagedAttachment
import com.dshanywhere.core.network.DSHConnectionState
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHModelSelection
import com.dshanywhere.core.protocol.DSHSessionSummary
import com.dshanywhere.core.protocol.DSHSessionUsage
import com.dshanywhere.ui.theme.DSHColors
import java.util.Locale

/**
 * Composer chrome ported from ConversationView.swift: `DSHCompactComposer`,
 * `DSHComposerQuickActionsMenu`, `ModelMenu`, `ReasoningEffortMenu`,
 * `PermissionMenu`, `ContextRing`, `UsageFooter`, the send control, the draft
 * attachment strip and the session status bar.
 */

/** A staged upload plus a local identity (SwiftUI: DSHStagedAttachment carries a UUID). */
internal data class DraftAttachment(
    val id: Long,
    val staged: DSHStagedAttachment,
)

// MARK: - Compact composer card

/**
 * SwiftUI: `DSHCompactComposer` — VStack(spacing: 5) of a plain growing text
 * field and a 10pt-spaced control row, on an ultraThinMaterial rounded-20 card.
 */
@Composable
private fun DSHCompactComposer(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    hasAttachments: Boolean,
    onSubmit: () -> Unit,
    controls: @Composable RowScope.() -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                // SwiftUI: .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
                DSHColors.thinMaterial(),
                RoundedCornerShape(20.dp),
            )
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        ComposerTextField(
            text = text,
            onTextChange = onTextChange,
            placeholder = placeholder,
            // SwiftUI: `.onSubmit { if canSubmit { onSubmit() } }`
            onSubmit = {
                if (text.isNotBlank() || hasAttachments) onSubmit()
            },
        )
        Row(
            modifier = Modifier
                .fillMaxWidth()
                // Ported size rule: the send box keeps a 52pt visual row height.
                .heightIn(min = 52.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            content = controls,
        )
    }
}

/**
 * The plain growing field shared by both composer layouts:
 * SwiftUI `TextField(_, text:, axis: .vertical).lineLimit(1...5)`
 * `.textFieldStyle(.plain)` at 17pt.
 *
 * SwiftUI: lineLimit(1...5) maps to maxLines=5; the `.plain` style maps to a
 * fully transparent Material decoration. The keyboard action button plays the
 * role of SwiftUI's `.onSubmit`.
 */
@Composable
private fun ComposerTextField(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    onSubmit: () -> Unit,
) {
    val focusManager = LocalFocusManager.current
    TextField(
        value = text,
        onValueChange = onTextChange,
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 26.dp, max = 120.dp),
        textStyle = TextStyle(fontSize = 17.sp),
        placeholder = {
            Text(
                placeholder,
                style = TextStyle(fontSize = 17.sp),
                color = DSHColors.secondaryLabel(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Color.Transparent,
            unfocusedContainerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            cursorColor = MaterialTheme.colorScheme.primary,
        ),
        shape = RoundedCornerShape(0.dp),
        // SwiftUI `.onSubmit`: keyboard action button sends.
        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
        keyboardActions = KeyboardActions(
            onSend = {
                onSubmit()
                focusManager.clearFocus()
            },
        ),
        maxLines = 5,
    )
}

// MARK: - Quick actions ("plus") menu

/**
 * SwiftUI: `DSHComposerQuickActionsMenu` — a native anchored menu with
 * Commands / Attach photo / Attach file behind a "plus" glyph.
 */
@Composable
private fun DSHComposerQuickActionsMenu(
    onCommand: () -> Unit,
    onPhoto: () -> Unit,
    onFile: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ComposerIconButton(
            icon = Icons.Filled.Add, // plus
            label = DSHLocalization.string("More actions"),
            onClick = { expanded = true },
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            DropdownMenuItem(
                leadingIcon = { Icon(Icons.Filled.Code, contentDescription = null) }, // slash.circle
                text = { Text(DSHLocalization.string("Commands")) },
                onClick = {
                    expanded = false
                    onCommand()
                },
            )
            DropdownMenuItem(
                leadingIcon = { Icon(Icons.Filled.PhotoCamera, contentDescription = null) }, // photo
                text = { Text(DSHLocalization.string("Attach photo")) },
                onClick = {
                    expanded = false
                    onPhoto()
                },
            )
            DropdownMenuItem(
                leadingIcon = { Icon(Icons.Filled.AttachFile, contentDescription = null) }, // paperclip
                text = { Text(DSHLocalization.string("Attach file")) },
                onClick = {
                    expanded = false
                    onFile()
                },
            )
        }
    }
}

/** A plain icon button matching the SwiftUI bare `Button { Image(systemName:) }`. */
@Composable
private fun ComposerIconButton(
    icon: ImageVector,
    label: String,
    iconSize: Int = 20, // SwiftUI .title3 == 20pt
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = label, modifier = Modifier.size(iconSize.dp))
    }
}

// MARK: - Model menu

/** SwiftUI: `ModelMenu`. */
@Composable
internal fun ModelMenu(sessionID: String, compact: Boolean = false) {
    val model = LocalAppModel.current
    var expanded by remember { mutableStateOf(false) }
    val catalog = model.modelCatalog
    Box {
        Row(
            modifier = Modifier
                .clickable { expanded = true }
                .padding(horizontal = 4.dp, vertical = 8.dp)
                .semantics { contentDescription = DSHLocalization.string("Model") },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(if (compact) 5.dp else 4.dp),
        ) {
            if (!compact) {
                Icon(
                    Icons.Filled.Memory, // cpu
                    contentDescription = null,
                    modifier = Modifier.size(14.dp),
                )
            }
            Text(
                modelCompactModelName(sessionID, compact),
                style = TextStyle(
                    fontSize = if (compact) 15.sp else 14.sp,
                    fontWeight = FontWeight.Normal,
                ),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!compact) {
                Icon(
                    Icons.Filled.ExpandMore, // chevron.up.chevron.down
                    contentDescription = null,
                    modifier = Modifier.size(11.dp),
                )
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (catalog != null) {
                catalog.groups.forEach { group ->
                    // SwiftUI: Section(group.name)
                    Text(
                        group.name,
                        style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold),
                        color = DSHColors.secondaryLabel(),
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
                    )
                    group.models.forEach { item ->
                        DropdownMenuItem(
                            leadingIcon = { Icon(Icons.Filled.Memory, contentDescription = null) }, // cpu
                            text = { Text(item.name) },
                            onClick = {
                                expanded = false
                                model.selectModel(
                                    DSHModelSelection(
                                        provider = group.id,
                                        model = item.id,
                                        reasoningEffort = item.reasoning?.defaultEffort,
                                    ),
                                    sessionID,
                                )
                            },
                        )
                    }
                }
            } else {
                DropdownMenuItem(
                    text = { Text(DSHLocalization.string("Refresh models")) },
                    onClick = {
                        expanded = false
                        model.sendModelCatalog()
                    },
                )
            }
        }
    }
}

/** SwiftUI `ModelMenu.displayName`: short name, plus the effort when compact. */
@Composable
private fun modelCompactModelName(sessionID: String, compact: Boolean): String {
    val model = LocalAppModel.current
    val base = model.shortModelName(sessionID)
    if (!compact) return base
    val effort = model.sessions.firstOrNull { it.id == sessionID }?.reasoningEffort
    if (effort.isNullOrEmpty()) return base
    return "$base · ${dshCapitalized(effort)}"
}

// MARK: - Reasoning effort menu

/** SwiftUI: `ReasoningEffortMenu` — absent when the catalog offers no choices. */
@Composable
internal fun ReasoningEffortMenu(sessionID: String) {
    val model = LocalAppModel.current
    val configuration = model.reasoningConfiguration(sessionID) ?: return
    var expanded by remember { mutableStateOf(false) }
    Box {
        Row(
            modifier = Modifier
                .clickable { expanded = true }
                .widthIn(max = 70.dp)
                .padding(horizontal = 4.dp, vertical = 8.dp)
                .semantics { contentDescription = DSHLocalization.string("Reasoning effort") },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(
                configuration.selectedEffort?.name ?: configuration.selectedEffortID,
                style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Normal),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Icon(
                Icons.Filled.ExpandMore, // chevron.up.chevron.down
                contentDescription = null,
                modifier = Modifier.size(11.dp),
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            configuration.efforts.forEach { effort ->
                DropdownMenuItem(
                    leadingIcon = {
                        if (effort.id == configuration.selectedEffortID) {
                            Icon(Icons.Filled.Check, contentDescription = null) // checkmark
                        } else {
                            // brain.head.profile
                            Icon(Icons.Filled.Psychology, contentDescription = null)
                        }
                    },
                    text = { Text(effort.name) },
                    onClick = {
                        expanded = false
                        model.selectModel(
                            DSHModelSelection(
                                provider = configuration.provider,
                                model = configuration.model,
                                reasoningEffort = effort.id,
                            ),
                            sessionID,
                        )
                    },
                )
            }
        }
    }
}

// MARK: - Permission menu

private data class PermissionMode(val mode: String, val title: String, val icon: ImageVector)

/** SwiftUI: `PermissionMenu.permissionLabel(_:)`. */
@Composable
internal fun permissionLabel(value: String): String = when (value) {
    "danger-full-access" -> DSHLocalization.string("Full access")
    "workspace-write" -> DSHLocalization.string("Workspace write")
    // read-only and ask arrive from sessions configured outside the app.
    "read-only" -> DSHLocalization.string("Read only")
    "ask" -> DSHLocalization.string("Ask")
    else -> DSHLocalization.string("Workspace write")
}

/**
 * SwiftUI: `PermissionMenu` — the three user-facing presets. "仅可查看" and
 * "完全权限" are Chinese literals in the iOS source and stay unwrapped.
 */
@Composable
internal fun PermissionMenu(sessionID: String, compact: Boolean = false) {
    val model = LocalAppModel.current
    var expanded by remember { mutableStateOf(false) }
    val currentMode = model.permissionModeFor(sessionID)
    val label = permissionLabel(currentMode)
    val modes = listOf(
        PermissionMode("read-only", "仅可查看", Icons.Filled.Visibility), // eye
        // folder
        PermissionMode("workspace-write", DSHLocalization.string("Workspace write"), Icons.Filled.Folder),
        // exclamationmark.triangle
        PermissionMode("danger-full-access", "完全权限", Icons.Filled.Warning),
    )
    Box {
        if (compact) {
            Row(
                modifier = Modifier
                    .clickable { expanded = true }
                    .padding(horizontal = 4.dp, vertical = 8.dp)
                    .semantics {
                        contentDescription = "${DSHLocalization.string("Permission")}: $label"
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    Icons.Filled.Shield, // checkmark.shield
                    contentDescription = null,
                    modifier = Modifier.size(20.dp), // .font(.title3)
                )
                Text(
                    label,
                    style = TextStyle(fontSize = 14.sp, fontWeight = FontWeight.Normal),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        } else {
            // Icon only: the mode is still announced (SwiftUI comment).
            ComposerIconButton(
                icon = Icons.Filled.Shield, // checkmark.shield
                label = "${DSHLocalization.string("Permission")}: $label",
                onClick = { expanded = true },
            )
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            modes.forEach { item ->
                DropdownMenuItem(
                    leadingIcon = {
                        if (currentMode == item.mode) {
                            Icon(Icons.Filled.Check, contentDescription = null) // checkmark
                        } else {
                            Icon(item.icon, contentDescription = null)
                        }
                    },
                    text = { Text(item.title) },
                    onClick = {
                        expanded = false
                        model.setPermission(item.mode, sessionID)
                    },
                )
            }
        }
    }
}

// MARK: - Context ring

/** SwiftUI: `ContextRing` — a 20pt ring drawn with two Circle().stroke layers. */
@Composable
internal fun ContextRing(ratio: Double) {
    val accent = MaterialTheme.colorScheme.primary
    val track = DSHColors.secondaryLabel().copy(alpha = 0.22f)
    val progress = if (ratio > 0.9) DSHColors.systemOrange() else accent
    Canvas(
        modifier = Modifier
            .size(20.dp)
            .semantics {
                contentDescription = "Context ${(ratio * 100).toInt()} percent used"
            },
    ) {
        // SwiftUI: Circle().stroke(Color.secondary.opacity(0.22), lineWidth: 2.5)
        drawCircle(
            color = track,
            style = Stroke(width = 2.5.dp.toPx()),
        )
        if (ratio > 0) {
            // SwiftUI: Circle().trim(from: 0, to: ratio) … .rotationEffect(.degrees(-90))
            drawArc(
                color = progress,
                startAngle = -90f,
                sweepAngle = (360f * ratio.toFloat()).coerceAtMost(360f),
                useCenter = false,
                style = Stroke(width = 2.5.dp.toPx(), cap = StrokeCap.Round),
            )
        }
    }
}

// MARK: - Usage footer

/** SwiftUI: `UsageFooter` — one centred caption2 row with four metrics. */
@Composable
internal fun UsageFooter(usage: DSHSessionUsage?) {
    val mono = TextStyle(
        fontSize = 11.sp, // .caption2
        fontFamily = FontFamily.Monospace, // monospacedDigit stand-in
        color = DSHColors.secondaryLabel(),
    )
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        // .frame(maxWidth: .infinity, alignment: .center) + HStack(spacing: 5)
        horizontalArrangement = Arrangement.spacedBy(5.dp, Alignment.CenterHorizontally),
    ) {
        // gauge.with.dots.needle.67percent
        UsageMetric(Icons.Filled.Equalizer, activityText(usage), mono)
        UsageSeparator(mono)
        UsageMetric(Icons.Filled.Speed, speedText(usage), mono) // speedometer
        UsageSeparator(mono)
        UsageMetric(Icons.Filled.DataUsage, tokenText(usage), mono) // chart.bar.xaxis
        UsageSeparator(mono)
        // externaldrive.badge.checkmark
        UsageMetric(Icons.Filled.SaveAlt, cacheText(usage), mono)
    }
}

@Composable
private fun UsageSeparator(mono: TextStyle) {
    // SwiftUI: Text("·").foregroundStyle(.quaternary)
    Text("·", style = mono, color = DSHColors.quaternaryLabel())
}

@Composable
private fun UsageMetric(icon: ImageVector, text: String, mono: TextStyle) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(9.dp))
        Text(text, style = mono, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private fun activityText(usage: DSHSessionUsage?): String {
    if (usage?.rounds == null && usage?.steps == null) return "—"
    return "${usage?.rounds ?: 0}r/${usage?.steps ?: 0}s"
}

private fun speedText(usage: DSHSessionUsage?): String {
    val speed = usage?.tokensPerSecond ?: return "—"
    return "${speed.toInt()} tok/s"
}

private fun tokenText(usage: DSHSessionUsage?): String {
    val total = usage?.totalTokens ?: return "—"
    return "${dshCompactNumber(total)} tok"
}

private fun cacheText(usage: DSHSessionUsage?): String {
    val hit = usage?.cacheHitPercent ?: return "—"
    // Two decimals, rounded rather than truncated (SwiftUI comment kept).
    return String.format(Locale.US, "%.2f%%", hit)
}

// MARK: - Send control

/** SwiftUI: `composerSendControl` — spinner while sending, stop while running. */
@Composable
private fun ComposerSendControl(
    isSending: Boolean,
    isRunning: Boolean,
    canSend: Boolean,
    onSend: () -> Unit,
    onCancelTurn: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    when {
        isSending -> {
            // SwiftUI: ProgressView().controlSize(.small)
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    color = accent,
                    strokeWidth = 2.dp,
                )
            }
        }

        isRunning -> {
            // stop.circle.fill at .font(.title) == 28pt, .foregroundStyle(.red)
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clickable { onCancelTurn() }
                    .semantics { contentDescription = DSHLocalization.string("Stop turn") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.StopCircle,
                    contentDescription = DSHLocalization.string("Stop turn"),
                    modifier = Modifier.size(28.dp),
                    tint = DSHColors.systemRed(),
                )
            }
        }

        else -> {
            // arrow.up.circle.fill; `.disabled(draft.isEmpty && !hasAttachments)`
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clickable(enabled = canSend) { onSend() }
                    .semantics { contentDescription = DSHLocalization.string("Send message") },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Filled.ArrowCircleUp,
                    contentDescription = DSHLocalization.string("Send message"),
                    modifier = Modifier.size(28.dp), // .font(.title) == 28pt
                    tint = if (canSend) accent else accent.copy(alpha = 0.35f),
                )
            }
        }
    }
}

// MARK: - Draft attachment strip

/** SwiftUI: `draftAttachmentStrip` — horizontal capsule chips above the card. */
@Composable
private fun DraftAttachmentStrip(
    attachments: List<DraftAttachment>,
    onRemove: (Long) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        attachments.forEach { item ->
            val staged = item.staged
            // SwiftUI: UIImage(data: attachment.data) for image chips.
            val bitmap = remember(staged) {
                if (staged.isImage) {
                    runCatching {
                        BitmapFactory.decodeByteArray(staged.data, 0, staged.data.size)
                    }.getOrNull()
                } else {
                    null
                }
            }
            Row(
                modifier = Modifier
                    .background(DSHColors.thinMaterial(), CircleShape)
                    .padding(start = 8.dp, end = 6.dp, top = 5.dp, bottom = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (staged.isImage && bitmap != null) {
                    Image(
                        bitmap = bitmap.asImageBitmap(),
                        contentDescription = null,
                        modifier = Modifier
                            .size(28.dp)
                            .clip(RoundedCornerShape(6.dp)),
                        contentScale = ContentScale.Crop,
                    )
                }
                Icon(
                    // photo / paperclip
                    if (staged.isImage) Icons.Filled.PhotoCamera else Icons.Filled.AttachFile,
                    contentDescription = null,
                    modifier = Modifier.size(12.dp), // .font(.caption)
                )
                Text(
                    staged.name,
                    style = TextStyle(fontSize = 12.sp), // .caption
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    modifier = Modifier
                        .clickable { onRemove(item.id) }
                        .semantics { contentDescription = DSHLocalization.string("Remove attachment") },
                ) {
                    Icon(
                        Icons.Filled.Cancel, // xmark.circle.fill
                        contentDescription = DSHLocalization.string("Remove attachment"),
                        modifier = Modifier.size(14.dp), // .font(.caption)
                        tint = DSHColors.secondaryLabel(),
                    )
                }
            }
        }
    }
}

// MARK: - Session status bar

/** SwiftUI: `sessionStatusBar` — Online/Offline on the left, branch on the right. */
@Composable
private fun SessionStatusBar(session: DSHSessionSummary?) {
    val model = LocalAppModel.current
    // Swift ConversationView switches both dot colour and label on deviceStatus.
    val status = model.deviceStatus
    val statusColor = when (status) {
        DSHDeviceStatus.Offline -> DSHColors.systemGray()
        DSHDeviceStatus.Error -> DSHColors.systemRed()
        DSHDeviceStatus.Online -> DSHColors.systemGreen()
        DSHDeviceStatus.ApprovalRequired -> DSHColors.systemYellow()
    }
    val branch = session?.branch?.trim().takeUnless { it.isNullOrEmpty() } ?: "main"
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .padding(bottom = 1.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(
                Modifier
                    .size(7.dp)
                    .background(statusColor, CircleShape),
            )
            Text(
                DSHLocalization.string(
                    when (status) {
                        DSHDeviceStatus.Offline -> "Offline"
                        DSHDeviceStatus.Error -> "Error"
                        DSHDeviceStatus.Online -> "Online"
                        DSHDeviceStatus.ApprovalRequired -> "Permission confirmation required"
                    },
                ),
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Medium),
                color = statusColor,
            )
        }
        Spacer(Modifier.weight(1f).widthIn(min = 8.dp))
        CompositionLocalProvider(LocalContentColor provides DSHColors.secondaryLabel()) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(
                    Icons.Filled.CallSplit, // arrow.triangle.branch
                    contentDescription = null,
                    modifier = Modifier.size(12.dp),
                )
                Text(
                    branch,
                    style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal),
                    maxLines = 1,
                )
            }
        }
    }
}

// MARK: - Full composer section

/**
 * SwiftUI: `ConversationView.composer` — attachment strip, the persistent
 * status row, the compact or expanded editor, and the usage footer.
 */
@Composable
internal fun ConversationComposerSection(
    sessionID: String,
    session: DSHSessionSummary?,
    draftAttachments: List<DraftAttachment>,
    hasRenderedContent: Boolean,
    isSending: Boolean,
    isRunning: Boolean,
    onSend: () -> Unit,
    onCancelTurn: () -> Unit,
    onCommands: () -> Unit,
    onPhoto: () -> Unit,
    onFile: () -> Unit,
    onRemoveAttachment: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = LocalAppModel.current
    val draft = model.draft
    val hasDraftAttachments = draftAttachments.isNotEmpty()
    val usage = model.usageFor(sessionID)
    // SwiftUI: contextRatio = clamp01(contextUsed / contextWindow) when both present.
    val ratio: Double? = usage?.let {
        val used = it.contextUsed
        val window = it.contextWindow
        if (used != null && window != null && window > 0) {
            (used / window).coerceIn(0.0, 1.0)
        } else {
            null
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .padding(vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        if (hasDraftAttachments) {
            DraftAttachmentStrip(draftAttachments) { id -> onRemoveAttachment(id) }
        }

        // Keep reachability and branch visible while reading a running
        // conversation too (SwiftUI comment).
        SessionStatusBar(session)

        val placeholder =
            DSHLocalization.string("Send a message, / command, @ file or conversation")
        if (model.collapseComposerControls) {
            DSHCompactComposer(
                text = draft,
                onTextChange = { model.draft = it },
                placeholder = placeholder,
                hasAttachments = hasDraftAttachments,
                onSubmit = onSend,
            ) {
                DSHComposerQuickActionsMenu(
                    onCommand = onCommands,
                    onPhoto = onPhoto,
                    onFile = onFile,
                )
                PermissionMenu(sessionID, compact = true)
                Spacer(Modifier.weight(1f).widthIn(min = 4.dp))
                ModelMenu(sessionID)
                ReasoningEffortMenu(sessionID)
                ratio?.let { ContextRing(it) }
                ComposerSendControl(
                    isSending = isSending,
                    isRunning = isRunning,
                    canSend = draft.isNotBlank() || hasDraftAttachments,
                    onSend = onSend,
                    onCancelTurn = onCancelTurn,
                )
            }
        } else {
            // SwiftUI: expandedComposer — VStack(spacing: 8) on the same card chrome.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(DSHColors.thinMaterial(), RoundedCornerShape(20.dp))
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // SwiftUI: TextField(..., axis: .vertical).lineLimit(1...5).plain
                //          .onSubmit { send() }
                ComposerTextField(
                    text = draft,
                    onTextChange = { model.draft = it },
                    placeholder = placeholder,
                    onSubmit = onSend,
                )
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        // Ported size rule: the send box keeps a 52pt visual row height.
                        .heightIn(min = 52.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    ComposerIconButton(
                        icon = Icons.Filled.Code, // slash.circle
                        label = DSHLocalization.string("Commands"),
                        onClick = onCommands,
                    )
                    ComposerIconButton(
                        icon = Icons.Filled.PhotoCamera, // photo
                        label = DSHLocalization.string("Attach photo"),
                        onClick = onPhoto,
                    )
                    ComposerIconButton(
                        icon = Icons.Filled.AttachFile, // paperclip
                        label = DSHLocalization.string("Attach file"),
                        onClick = onFile,
                    )
                    PermissionMenu(sessionID)
                    Spacer(Modifier.weight(1f).widthIn(min = 4.dp))
                    ModelMenu(sessionID)
                    ReasoningEffortMenu(sessionID)
                    ratio?.let { ContextRing(it) }
                    ComposerSendControl(
                        isSending = isSending,
                        isRunning = isRunning,
                        canSend = draft.isNotBlank() || hasDraftAttachments,
                        onSend = onSend,
                        onCancelTurn = onCancelTurn,
                    )
                }
            }
        }

        if (hasRenderedContent && model.showUsageFooter) {
            UsageFooter(usage)
        }
    }
}
