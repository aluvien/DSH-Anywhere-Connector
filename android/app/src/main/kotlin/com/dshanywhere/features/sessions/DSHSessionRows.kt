package com.dshanywhere.features.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChatBubble
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHSessionSummary
import com.dshanywhere.ui.theme.DSHColors

// ---------------------------------------------------------------------------
// SessionRow — Swift `private struct SessionRow` (SessionListView.swift).
// Used by the flat home list with `showWorkspaceName = true`; the compact
// leading-dot variant is kept for 1:1 parity with the SwiftUI flag.
// ---------------------------------------------------------------------------

@Composable
internal fun SessionRow(
    session: DSHSessionSummary,
    showWorkspaceName: Boolean,
    openSession: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = LocalAppModel.current
    // iOS `isHighlighted: session.running == true || model.isSessionUnread(session)`
    val highlighted = session.running == true || model.isSessionUnread(session)
    var menuExpanded by remember { mutableStateOf(false) }
    // Swift: NavigationLink(value:) tap plus `.contextMenu` with the single
    // Archive/Unarchive button.
    DSHRowContextMenu(
        expanded = menuExpanded,
        onExpand = { menuExpanded = true },
        onDismissRequest = { menuExpanded = false },
        onClick = openSession,
        menuOffsetX = if (showWorkspaceName) 16 else 48,
        menuWidth = 220.dp,
        menuContent = {
            ArchiveMenuRow(model, session) { menuExpanded = false }
        },
    ) {
        val updatedLabel = dshUpdatedLabel(session.updatedAt)
        Row(
            modifier
                .fillMaxWidth()
                // Swift: .padding(.leading, showWorkspaceName ? 16 : 48)
                //        .padding(.trailing, 22).padding(.vertical, 11)
                .padding(
                    start = if (showWorkspaceName) 16.dp else 48.dp,
                    end = 22.dp,
                    top = 11.dp,
                    bottom = 11.dp,
                ),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            if (showWorkspaceName) {
                // Image "bubble.left" 15 medium inside a 28×28 rounded tile,
                // tertiarySystemBackground.
                Box(
                    Modifier
                        .size(28.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(DSHColors.tertiarySystemBackground()),
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.ChatBubble, // bubble.left
                        DSHLocalization.string("Session icon"),
                        15,
                        tint = if (highlighted) DSHColors.systemGreen() else dshSecondary(),
                    )
                }
            } else {
                // Circle 7×7: running green, otherwise secondary @ 0.55.
                Box(
                    Modifier
                        .size(7.dp)
                        .clip(CircleShape)
                        .background(
                            if (highlighted) DSHColors.systemGreen()
                            else DSHColors.secondaryLabel().copy(alpha = 0.55f),
                        ),
                )
            }

            Column(Modifier.weight(1f)) {
                Text(
                    session.title.ifEmpty { DSHLocalization.string("Untitled session") },
                    fontSize = 17.sp, // .font(.body.weight(.medium))
                    fontWeight = FontWeight.Medium,
                    color = dshPrimary(),
                    maxLines = 2, // .lineLimit(2)
                )
                if (showWorkspaceName) {
                    val workspace = session.workspaceName?.trim().orEmpty()
                    if (workspace.isNotEmpty()) {
                        Text(
                            workspace,
                            fontSize = 12.sp, // .caption
                            color = dshSecondary(),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            // Swift Spacer(minLength: 8) + timestamp with layoutPriority(1):
            // in a Row the unweighted timestamp keeps its full width and the
            // weighted title column absorbs the remainder — equivalent.
            if (showWorkspaceName && updatedLabel.isNotEmpty()) {
                Text(
                    updatedLabel,
                    fontSize = 12.sp, // .caption
                    fontFamily = FontFamily.Monospace, // .monospacedDigit()
                    color = dshSecondary(),
                    modifier = Modifier.padding(start = 8.dp),
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// GroupedSessionRow — Swift `private struct GroupedSessionRow`.
// Rows inside a workspace card: compact icon tile, one-line title, recency and
// a disclosure arrow. The workspace name is intentionally omitted because the
// enclosing card already provides that context.
// ---------------------------------------------------------------------------

@Composable
internal fun GroupedSessionRow(
    session: DSHSessionSummary,
    openSession: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = LocalAppModel.current
    val highlighted = session.running == true || model.isSessionUnread(session)
    var menuExpanded by remember { mutableStateOf(false) }
    DSHRowContextMenu(
        expanded = menuExpanded,
        onExpand = { menuExpanded = true },
        onDismissRequest = { menuExpanded = false },
        onClick = openSession,
        menuOffsetX = 20,
        menuWidth = 220.dp,
        menuContent = {
            ArchiveMenuRow(model, session) { menuExpanded = false }
        },
    ) {
        val title = session.title.ifEmpty { DSHLocalization.string("Untitled session") }
        val updatedLabel = dshUpdatedLabel(session.updatedAt)
        Row(
            modifier
                .fillMaxWidth()
                // Swift: .padding(.horizontal, 20).padding(.vertical, 10)
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Icon tile chosen by the Swift `iconName` keyword heuristic.
            Box(
                Modifier
                    .size(36.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(DSHColors.tertiarySystemBackground()),
                contentAlignment = Alignment.Center,
            ) {
                DSHLocalIcon(
                    groupedRowIcon(title),
                    DSHLocalization.string("Session icon"),
                    17,
                    tint = if (highlighted) DSHColors.systemGreen() else dshPrimary(),
                )
            }

            Text(
                title,
                fontSize = 17.sp, // .body.weight(.medium)
                fontWeight = FontWeight.Medium,
                color = dshPrimary(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )

            if (updatedLabel.isNotEmpty()) {
                Text(
                    updatedLabel,
                    fontSize = 12.sp, // .caption
                    fontFamily = FontFamily.Monospace, // .monospacedDigit()
                    color = dshSecondary(),
                    modifier = Modifier.padding(start = 8.dp), // Spacer(minLength: 8)
                )
            }

            // "chevron.right" caption semibold
            DSHLocalIcon(
                Icons.Filled.KeyboardArrowRight, // chevron.right
                null,
                12,
                tint = dshSecondary(),
            )
        }
    }
}

/** Swift: `GroupedSessionRow.iconName` keyword heuristic. */
private fun groupedRowIcon(title: String): ImageVector {
    val normalized = title.lowercase()
    return when {
        normalized.contains("bash") || normalized.contains("run ") ||
            normalized.contains("eval") || normalized.contains("terminal") ->
            Icons.Filled.Code // chevron.left.forwardslash.chevron.right
        normalized.contains("code") || normalized.contains("refactor") ||
            normalized.contains("model") || normalized.contains("read") ->
            Icons.Filled.Description // doc.text
        else -> Icons.Filled.ChatBubble // bubble.left
    }
}

// ---------------------------------------------------------------------------
// HappySessionRow — Swift `private struct HappySessionRow`.
// Flat activity row used by the Happy home screen: 60pt avatar, 17pt title,
// green dot for active sessions, timestamp in a fixed right slot.
// NOTE: like DSHHappyAvatar this type is unreferenced in the Swift file
// (dead code); ported for completeness because the task asks for every type.
// ---------------------------------------------------------------------------

@Composable
internal fun HappySessionRow(
    session: DSHSessionSummary,
    openSession: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val model = LocalAppModel.current
    val highlighted = session.running == true || model.isSessionUnread(session)
    var menuExpanded by remember { mutableStateOf(false) }
    DSHRowContextMenu(
        expanded = menuExpanded,
        onExpand = { menuExpanded = true },
        onDismissRequest = { menuExpanded = false },
        onClick = openSession,
        menuOffsetX = 16,
        menuWidth = 220.dp,
        menuContent = {
            // The Swift view itself carries no `.contextMenu`; keep one anyway
            // so the row remains operable. (Deviation noted in the report.)
            ArchiveMenuRow(LocalAppModel.current, session) { menuExpanded = false }
        },
    ) {
        val title = session.title.ifEmpty { DSHLocalization.string("Untitled session") }
        val updatedLabel = dshUpdatedLabel(session.updatedAt)
        Row(
            modifier
                .fillMaxWidth()
                // Swift: .padding(.horizontal, 16).padding(.vertical, 10)
                .padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            DSHHappyAvatar(size = 60.dp, faded = session.archived == true)

            Column(
                Modifier.weight(1f), // .frame(maxWidth: .infinity, alignment: .leading)
                horizontalAlignment = Alignment.Start,
            ) {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        title,
                        fontSize = 17.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = when {
                            session.archived == true -> dshSecondary()
                            highlighted -> DSHColors.systemGreen()
                            else -> dshPrimary()
                        },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (session.running == true) {
                        Box(
                            Modifier
                                .size(7.dp)
                                .clip(CircleShape)
                                .background(DSHColors.systemGreen()),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    if (updatedLabel.isNotEmpty()) {
                        Text(
                            updatedLabel,
                            fontSize = 13.sp,
                            fontFamily = FontFamily.Monospace, // .monospacedDigit()
                            color = dshSecondary(),
                        )
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Shared menu pieces
// ---------------------------------------------------------------------------

/** The single Archive/Unarchive item in each row's `.contextMenu`. */
@Composable
private fun ArchiveMenuRow(model: DSHAppModel, session: DSHSessionSummary, dismiss: () -> Unit) {
    val isArchived = session.archived == true
    DSHMenuRow(
        icon = if (isArchived) Icons.Filled.Unarchive else Icons.Filled.Archive, // tray.and.arrow.up / archivebox
        text = DSHLocalization.string(if (isArchived) "Unarchive" else "Archive"),
        onClick = {
            model.archive(session, archived = !isArchived)
            dismiss()
        },
    )
}
