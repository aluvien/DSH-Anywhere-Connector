package com.dshanywhere.features.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Feedback
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Adjust
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Compress
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.ui.theme.DSHColors

// ---------------------------------------------------------------------------
// DSHSessionsCompactComposer — Swift `DSHCompactComposer` (defined in
// ios/DSHAnywhere/Features/Conversation/ConversationView.swift, used here by
// NewSessionSheet). A *simplified* local copy lives in this package so the
// sessions port does not wait for the conversation port, per the task brief.
// ---------------------------------------------------------------------------

@Composable
internal fun DSHSessionsCompactComposer(
    text: String,
    onTextChange: (String) -> Unit,
    placeholder: String,
    hasAttachments: Boolean,
    onSubmit: () -> Unit,
    modifier: Modifier = Modifier,
    controls: @Composable RowScope.() -> Unit,
) {
    // Swift: `canSubmit = !text.trimmed.isEmpty || hasAttachments`
    val canSubmit = text.trim().isNotEmpty() || hasAttachments
    Column(
        modifier
            .fillMaxWidth()
            .background(dshMaterial(), RoundedCornerShape(20.dp)) // .ultraThinMaterial in .rect(cornerRadius:20)
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        BasicTextField(
            value = text,
            onValueChange = onTextChange,
            textStyle = TextStyle(fontSize = 17.sp, color = dshPrimary()),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Text,
                // Swift TextField(axis: .vertical) + .onSubmit: the hardware
                // return submits when the text is submittable.
                imeAction = ImeAction.Send,
            ),
            keyboardActions = KeyboardActions(
                onSend = { if (canSubmit) onSubmit() },
            ),
            maxLines = 5, // .lineLimit(1...5)
            cursorBrush = SolidColor(DSHColors.systemBlue()),
            decorationBox = { inner ->
                Box {
                    if (text.isEmpty()) {
                        Text(placeholder, fontSize = 17.sp, color = dshSecondary())
                    }
                    inner()
                }
            },
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            content = controls,
        )
    }
}

// ---------------------------------------------------------------------------
// DSHSessionsQuickActionsMenu — Swift `DSHComposerQuickActionsMenu`: the plus
// menu with exactly Commands / Attach photo / Attach file.
// ---------------------------------------------------------------------------

@Composable
internal fun DSHSessionsQuickActionsMenu(
    onCommand: () -> Unit,
    onPhoto: () -> Unit,
    onFile: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box(
            Modifier
                .size(32.dp)
                .clickableRow { expanded = true },
            contentAlignment = Alignment.Center,
        ) {
            // Image "plus" .font(.title3)
            DSHLocalIcon(Icons.Filled.Add, DSHLocalization.string("More actions"), 20)
        }
        DSHDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, width = 230.dp) {
            DSHMenuRow(
                icon = Icons.Filled.Terminal, // slash.circle (slash_command in 1.7.8; Terminal chosen)
                text = DSHLocalization.string("Commands"),
                onClick = { expanded = false; onCommand() },
            )
            DSHMenuRow(
                icon = Icons.Filled.Photo, // photo
                text = DSHLocalization.string("Attach photo"),
                onClick = { expanded = false; onPhoto() },
            )
            DSHMenuRow(
                icon = Icons.Filled.AttachFile, // paperclip
                text = DSHLocalization.string("Attach file"),
                onClick = { expanded = false; onFile() },
            )
        }
    }
}

// ---------------------------------------------------------------------------
// DSHSessionsCommandMenuSheet — Swift `CommandMenuSheet`
// (ConversationView.swift, `.presentationDetents([.medium])`).
//
// The iOS sheet binds a PhotosPicker inside itself; here the pickers are
// hoisted to NewSessionSheet (Android activity-result launchers) and simply
// dismiss this sheet when invoked — the same net interaction: choosing Photo
// closes the command sheet (`onChange(of: selectedPhoto) … onDismiss()` in
// Swift) and opens the system picker.
// ---------------------------------------------------------------------------

private data class DSHCommandEntry(val command: String, val gloss: String, val icon: androidx.compose.ui.graphics.vector.ImageVector)

private val dshCommandEntries = listOf(
    // Swift (command, Chinese gloss, SF Symbol) — verbatim.
    DSHCommandEntry("compact", "压缩以上对话内容", Icons.Filled.Compress), // rectangle.compress.vertical
    DSHCommandEntry("export", "将当前会话导出为 ZIP", Icons.Filled.Share), // square.and.arrow.up
    DSHCommandEntry("feedback", "发送关于当前会话的反馈", Icons.Filled.Feedback), // bubble.left.and.exclamationmark.bubble.right
    DSHCommandEntry("goal", "设置或查看长期任务目标", Icons.Filled.Adjust), // target
    DSHCommandEntry("permission", "切换权限预设（沙箱模式与审批策略）", Icons.Filled.Shield), // checkmark.shield
    DSHCommandEntry("plan", "进入或退出计划模式", Icons.Filled.Assignment), // list.clipboard
    DSHCommandEntry("model", "选择本会话使用的模型", Icons.Filled.Memory), // cpu
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DSHSessionsCommandMenuSheet(
    onDismiss: () -> Unit,
    onPhoto: () -> Unit,
    onFile: () -> Unit,
    onCommand: (String) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = DSHColors.systemBackground(),
    ) {
        // safeAreaInset(top) { HappySheetHeader(title: "Commands", onClose,
        //                                        trailingTitle: "Done", …) }
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onDismiss) {
                DSHLocalIcon(Icons.Filled.Close, DSHLocalization.string("Close"), 18, tint = dshPrimary()) // xmark
            }
            Text(
                DSHLocalization.string("Commands"),
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold, // .headline centred
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            TextButton(onClick = onDismiss) {
                Text(DSHLocalization.string("Done"), color = DSHColors.systemBlue(), fontSize = 16.sp)
            }
        }

        Column(
            Modifier
                .fillMaxWidth()
                .height(360.dp)
                .verticalScroll(androidx.compose.foundation.rememberScrollState()),
        ) {
            // Section("Attachments")
            DSHMenuSectionHeader(DSHLocalization.string("Attachments"))
            DSHMenuRow(
                icon = Icons.Filled.Photo, // photo
                text = DSHLocalization.string("Photo"),
                onClick = onPhoto,
            )
            DSHMenuRow(
                icon = Icons.Filled.AttachFile, // paperclip
                text = DSHLocalization.string("File"),
                onClick = onFile,
            )

            // Section("Commands")
            DSHMenuSectionHeader(DSHLocalization.string("Commands"))
            for (entry in dshCommandEntries) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickableRow { onCommand(entry.command) }
                        .padding(horizontal = 14.dp, vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
                        DSHLocalIcon(entry.icon, null, 17, tint = DSHColors.systemBlue())
                    }
                    Spacer(Modifier.width(10.dp))
                    // Text("/\(command)").monospaced().tint + gloss
                    Text(
                        "/${entry.command}",
                        fontSize = 16.sp,
                        fontFamily = FontFamily.Monospace,
                        color = DSHColors.systemBlue(),
                    )
                    Text(" ${entry.gloss}", fontSize = 16.sp, color = dshPrimary())
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}
