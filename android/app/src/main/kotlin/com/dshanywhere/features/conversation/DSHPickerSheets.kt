package com.dshanywhere.features.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Assignment
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.CenterFocusStrong
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHModelSelection
import com.dshanywhere.ui.theme.DSHColors

/**
 * Sheets ported from ConversationView.swift: `CommandMenuSheet`,
 * `ModelPickerSheet`, `PermissionPickerSheet` and the shared
 * `HappySheetHeader` chrome. `.sheet` + `presentationDetents` maps to
 * Material3 `ModalBottomSheet`.
 */

// MARK: - Happy sheet header

/**
 * SwiftUI: `HappySheetHeader` — 44pt close circle, centred title, optional
 * trailing action; used by all three pickers.
 */
@Composable
internal fun HappySheetHeader(
    title: String,
    onClose: () -> Unit,
    trailingTitle: String? = null,
    trailingAction: (() -> Unit)? = null,
) {
    val accent = MaterialTheme.colorScheme.primary
    Row(
        modifier = Modifier
            .fillMaxWidth()
            // .background(Color(.systemBackground).opacity(0.96))
            .background(DSHColors.systemBackground().copy(alpha = 0.96f))
            .padding(horizontal = 16.dp)
            .padding(top = 4.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            modifier = Modifier
                .size(44.dp)
                // .ultraThinMaterial Circle + primary 14% stroke, 0.75pt.
                .clip(CircleShape)
                .background(DSHColors.thinMaterial())
                .border(0.75.dp, DSHColors.label().copy(alpha = 0.14f), CircleShape)
                .clickable(onClick = onClose)
                .semantics { contentDescription = DSHLocalization.string("Close") },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.Close, // xmark
                contentDescription = null,
                modifier = Modifier.size(16.dp), // .font(.system(size: 16, weight: .semibold))
            )
        }

        Spacer(Modifier.weight(1f).widthIn(min = 0.dp))
        Text(
            title,
            style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.weight(1f).widthIn(min = 0.dp))

        if (trailingTitle != null && trailingAction != null) {
            Box(
                modifier = Modifier
                    .widthIn(min = 52.dp)
                    .heightIn(min = 44.dp)
                    .clickable(onClick = trailingAction),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    trailingTitle,
                    style = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold),
                    color = accent,
                )
            }
        } else {
            Spacer(Modifier.width(52.dp).height(44.dp))
        }
    }
}

/** Section header row inside the grouped sheets. */
@Composable
private fun SheetSectionHeader(title: String) {
    Text(
        title,
        style = TextStyle(fontSize = 13.sp),
        color = DSHColors.secondaryLabel(),
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier.padding(start = 20.dp, end = 16.dp, top = 14.dp, bottom = 4.dp),
    )
}

/** A simple icon + title row, styled like the iOS grouped List rows. */
@Composable
private fun SheetRow(icon: ImageVector, title: String, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 20.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(20.dp))
        Text(title, style = TextStyle(fontSize = 17.sp), color = DSHColors.label())
    }
}

// MARK: - Command menu sheet

private data class SlashCommand(val name: String, val gloss: String, val icon: ImageVector)

/**
 * SwiftUI: `CommandMenuSheet` — Attachments (Photo/File) + Commands sections.
 * The glosses are Chinese literals in the iOS source and stay unwrapped.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CommandMenuSheet(
    onPhoto: () -> Unit,
    onFile: () -> Unit,
    onCommand: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    val commands = listOf(
        SlashCommand("compact", "压缩以上对话内容", Icons.Filled.UnfoldLess), // rectangle.compress.vertical
        SlashCommand("export", "将当前会话导出为 ZIP", Icons.Filled.Upload), // square.and.arrow.up
        SlashCommand("feedback", "发送关于当前会话的反馈", Icons.Filled.Forum), // bubble.left.and.exclamationmark.bubble.right
        SlashCommand("goal", "设置或查看长期任务目标", Icons.Filled.CenterFocusStrong), // target
        SlashCommand("permission", "切换权限预设（沙箱模式与审批策略）", Icons.Filled.Shield), // checkmark.shield
        SlashCommand("plan", "进入或退出计划模式", Icons.AutoMirrored.Filled.Assignment), // list.clipboard
        SlashCommand("model", "选择本会话使用的模型", Icons.Filled.Memory), // cpu
    )
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(bottom = 24.dp)) {
            HappySheetHeader(
                title = DSHLocalization.string("Commands"),
                onClose = onDismiss,
                trailingTitle = DSHLocalization.string("Done"),
                trailingAction = onDismiss,
            )
            LazyColumn(Modifier.heightIn(max = 400.dp)) {
                item { SheetSectionHeader(DSHLocalization.string("Attachments")) }
                item {
                    // PhotosPicker row: picking a photo also dismisses the sheet
                    // (SwiftUI `.onChange(of: selectedPhoto)`).
                    SheetRow(
                        icon = Icons.Filled.PhotoCamera, // photo
                        title = DSHLocalization.string("Photo"),
                        onClick = { onPhoto() },
                    )
                }
                item {
                    SheetRow(
                        icon = Icons.Filled.AttachFile, // paperclip
                        title = DSHLocalization.string("File"),
                        onClick = { onFile() },
                    )
                }
                item { SheetSectionHeader(DSHLocalization.string("Commands")) }
                items(commands.size) { index ->
                    val command = commands[index]
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { onCommand(command.name) }
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Icon(
                            command.icon,
                            contentDescription = null,
                            modifier = Modifier.size(20.dp),
                            tint = MaterialTheme.colorScheme.primary, // .foregroundStyle(.tint)
                        )
                        // Icon, "/command", a space, then the Chinese gloss —
                        // teaches the slash syntax (SwiftUI comment).
                        Row(horizontalArrangement = Arrangement.spacedBy(0.dp)) {
                            Text(
                                "/${command.name}",
                                style = TextStyle(
                                    fontSize = 17.sp,
                                    fontFamily = FontFamily.Monospace,
                                ),
                                color = MaterialTheme.colorScheme.primary, // .tint
                            )
                            Text(
                                " ${command.gloss}",
                                style = TextStyle(fontSize = 17.sp),
                                color = DSHColors.label(),
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Model picker sheet

/** SwiftUI: `ModelPickerSheet`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun ModelPickerSheet(sessionID: String, onDismiss: () -> Unit) {
    val model = LocalAppModel.current
    val catalog = model.modelCatalog
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(bottom = 24.dp)) {
            HappySheetHeader(
                title = DSHLocalization.string("Select model"),
                onClose = onDismiss,
            )
            if (catalog == null) {
                // ContentUnavailableView("No model catalog", systemImage: "cpu", …)
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(32.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Filled.Memory, // cpu
                        contentDescription = null,
                        modifier = Modifier.size(40.dp),
                        tint = DSHColors.secondaryLabel(),
                    )
                    Text(
                        DSHLocalization.string("No model catalog"),
                        style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                    )
                    Text(
                        DSHLocalization.string("Reconnect to load available models."),
                        style = TextStyle(fontSize = 15.sp),
                        color = DSHColors.secondaryLabel(),
                        textAlign = TextAlign.Center,
                    )
                }
            } else {
                LazyColumn(Modifier.heightIn(max = 460.dp)) {
                    catalog.groups.forEach { group ->
                        item { SheetSectionHeader(group.name) }
                        items(group.models.size) { index ->
                            val item = group.models[index]
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        model.selectModel(
                                            DSHModelSelection(
                                                provider = group.id,
                                                model = item.id,
                                                reasoningEffort = item.reasoning?.defaultEffort,
                                            ),
                                            sessionID,
                                        )
                                        onDismiss()
                                    }
                                    .padding(horizontal = 20.dp, vertical = 10.dp),
                                verticalArrangement = Arrangement.spacedBy(3.dp),
                            ) {
                                Text(item.name, style = TextStyle(fontSize = 17.sp), color = DSHColors.label())
                                val description = item.description
                                if (!description.isNullOrEmpty()) {
                                    Text(
                                        description,
                                        style = TextStyle(fontSize = 12.sp),
                                        color = DSHColors.secondaryLabel(),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Permission picker sheet

/** SwiftUI: `PermissionPickerSheet`. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun PermissionPickerSheet(sessionID: String, onDismiss: () -> Unit) {
    val model = LocalAppModel.current
    // Chinese literals in the iOS source; unwrapped.
    val modes = listOf(
        "read-only" to "仅可查看",
        "workspace-write" to "工作区内修改",
        "danger-full-access" to "完全权限",
    )
    val current = model.permissionModeFor(sessionID)
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(bottom = 24.dp)) {
            HappySheetHeader(
                title = DSHLocalization.string("Permission"),
                onClose = onDismiss,
            )
            modes.forEach { (mode, title) ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            model.setPermission(mode, sessionID)
                            onDismiss()
                        }
                        .padding(horizontal = 20.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(title, style = TextStyle(fontSize = 17.sp), color = DSHColors.label())
                    Spacer(Modifier.weight(1f))
                    if (current == mode) {
                        Icon(
                            Icons.Filled.Check, // checkmark
                            contentDescription = null,
                            modifier = Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
        }
    }
}
