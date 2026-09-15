package com.dshanywhere.features.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Chat
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHDeviceStatus
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.core.network.DSHConnectionState
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.store.DSHSessionGroup
import com.dshanywhere.core.store.DSHSessionGrouping
import com.dshanywhere.core.store.DSHWorkspaceOption
import com.dshanywhere.core.store.FLAT_GROUP_ID
import com.dshanywhere.core.store.groupedForList
import com.dshanywhere.features.settings.SettingsScreen
import com.dshanywhere.ui.theme.DSHColors
import kotlinx.coroutines.delay

/// Ported 1:1 from `struct SessionListView` (ios/DSHAnywhere/Features/Sessions/
/// SessionListView.swift) — the home screen workspace browser.
///
/// Navigation: SwiftUI pushes `ConversationView` via a `NavigationStack` path.
/// Here [onOpenSession] performs the route push. The Swift
/// `.onChange(of: model.selectedSessionID)` handler (with its
/// `navigationPath.last != sessionID` dedup guard) becomes the
/// [LaunchedEffect] below; row taps deliberately share that one funnel so a
/// tap can never double-push the back stack.
@Composable
fun SessionListScreen(onOpenSession: (String) -> Unit) {
    val model = LocalAppModel.current

    // @State mirrors of the Swift view state.
    var didRefresh by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    // Swift seeds this from the `--dsh-preview-new-session` DEBUG launch
    // argument; MainActivity's `--es dsh-preview …` fixtures do not include
    // that flag, so the port starts closed.
    var showNewSession by remember { mutableStateOf(false) }
    var newSessionWorkspaceID by remember { mutableStateOf<String?>(null) }
    var showRenameWorkspace by remember { mutableStateOf(false) }
    var renameWorkspaceID by remember { mutableStateOf("") }
    var renameWorkspaceText by remember { mutableStateOf("") }
    var workspacePendingDeletion by remember { mutableStateOf<DSHSessionGroup?>(null) }
    var showDeleteWorkspaceConfirmation by remember { mutableStateOf(false) }
    // Dedup guard equivalent to Swift `if navigationPath.last != sessionID`.
    var lastOpenedSessionID by remember { mutableStateOf<String?>(null) }

    // .onChange(of: model.selectedSessionID) — programmatic navigation
    // (fires after `session.created` resolves on the model).
    LaunchedEffect(model.selectedSessionID) {
        val id = model.selectedSessionID ?: return@LaunchedEffect
        if (lastOpenedSessionID != id) {
            lastOpenedSessionID = id
            onOpenSession(id)
        }
        model.selectedSessionID = null
    }

    // Row taps (Swift NavigationLink) and programmatic opens share the guard.
    val openSession: (String) -> Unit = { id ->
        lastOpenedSessionID = id
        onOpenSession(id)
    }

    fun openNewSession(workspace: DSHWorkspaceOption? = null) {
        newSessionWorkspaceID = workspace?.id
        showNewSession = true
    }

    fun refreshSessions() {
        model.refreshSessions()
        // Swift: didRefresh = true; after 1.2 s back to false.
        didRefresh = true
    }
    fun beginRename(group: DSHSessionGroup) {
        renameWorkspaceID = group.id
        renameWorkspaceText = group.title
        showRenameWorkspace = true
    }
    LaunchedEffect(didRefresh) {
        if (didRefresh) {
            delay(1_200)
            didRefresh = false
        }
    }

    // /// Grouping, filtering and sorting live in Core so they are unit-tested;
    // /// this view only arranges what it is handed.
    val groups: List<DSHSessionGroup> = model.sessions
        .groupedForList(model.sessionGrouping, showArchived = model.showArchivedSessions)
        .filterNot { model.hiddenWorkspaceIDs.contains(it.id) }
        .map { group ->
            val title = if (group.id == FLAT_GROUP_ID) {
                group.title
            } else {
                model.workspaceDisplayNameFor(group.id, group.title)
            }
            group.copy(title = title)
        }

    /// Happy's phone home is a single activity-sorted chat column. Grouping
    /// remains available from the filter menu, but the flat view is the
    /// default so the first screen has the same visual rhythm as Happy.
    val flatSessions = model.sessions
        .groupedForList(DSHSessionGrouping.Flat, showArchived = model.showArchivedSessions)
        .flatMap { it.sessions }
        .filter { session ->
            val workspaceID = session.workspaceId
            workspaceID == null || !model.hiddenWorkspaceIDs.contains(workspaceID)
        }

    val hasVisibleSessions =
        if (model.groupsSessionsByWorkspace) groups.isNotEmpty() else flatSessions.isNotEmpty()
    val hasArchivedSessions = model.sessions.any { it.archived == true }

    Column(
        Modifier
            .fillMaxSize()
            .background(DSHColors.systemBackground()),
    ) {
        HappyHeader(
            model = model,
            didRefresh = didRefresh,
            onNewSession = { openNewSession() },
            onNewSessionIn = { openNewSession(it) },
            onRefresh = { refreshSessions() },
            onShowSettings = { showSettings = true },
        )

        Box(Modifier.weight(1f)) {
            // Swift ScrollView { LazyVStack(alignment: .leading, spacing: 0) }
            // with `.padding(.top, 8).padding(.bottom, 12)`.
            //
            // The per-mode `.id(...)` identity from SwiftUI is unnecessary:
            // LazyColumn keys (`ws-` / `s-` prefixes) make the row tree fully
            // re-build when the grouping switch flips.
            LazyColumn(
                Modifier.fillMaxSize(),
                contentPadding = PaddingValues(top = 8.dp, bottom = 12.dp),
            ) {
                if (model.groupsSessionsByWorkspace) {
                    items(groups, key = { "ws-${it.id}" }) { group ->
                        WorkspaceSection(
                            model = model,
                            group = group,
                            openSession = openSession,
                            onNewSessionIn = { openNewSession(it) },
                            onRefresh = { refreshSessions() },
                            onRename = { beginRename(it) },
                            onDelete = { group2 ->
                                workspacePendingDeletion = group2
                                showDeleteWorkspaceConfirmation = true
                            },
                        )
                    }
                    if (hasArchivedSessions && !model.showArchivedSessions && groups.isNotEmpty()) {
                        item(key = "archived-more") {
                            ArchivedSessionsButton(onShow = { model.setShowArchived(true) })
                        }
                    }
                } else {
                    itemsIndexed(flatSessions, key = { _, session -> "s-${session.id}" }) { index, session ->
                        Column {
                            SessionRow(
                                session = session,
                                showWorkspaceName = true,
                                openSession = { openSession(session.id) },
                            )
                            if (index < flatSessions.lastIndex) {
                                // Divider().padding(.leading, 48).opacity(0.52)
                                HorizontalDivider(
                                    modifier = Modifier.padding(start = 48.dp),
                                    thickness = 0.7.dp,
                                    color = DSHColors.separator().copy(alpha = 0.52f),
                                )
                            }
                        }
                    }
                    if (hasArchivedSessions) {
                        item(key = "archived-toggle") {
                            FlatShowHideArchivedButton(
                                showArchived = model.showArchivedSessions,
                                onToggle = { model.setShowArchived(!model.showArchivedSessions) },
                            )
                        }
                    }
                }
            }

            // .overlay { if model.hasLoadedSessions && !hasVisibleSessions {
            //              emptyHomeState } }
            if (model.hasLoadedSessions && !hasVisibleSessions) {
                EmptyHomeState(
                    model = model,
                    hasArchivedSessions = hasArchivedSessions,
                    onNewSession = { openNewSession() },
                    onShowSettings = { showSettings = true },
                    onShowArchived = { model.setShowArchived(true) },
                )
            }
        }

        HomeDock(onNewSession = { openNewSession() })
    }

    // .sheet(isPresented: $showSettings) { SettingsView()… } — spec: presented
    // by SessionListScreen as a dialog rendering the iOS NavigationStack sheet.
    if (showSettings) {
        Dialog(
            onDismissRequest = { showSettings = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(DSHColors.systemBackground()),
            ) {
                SettingsScreen(onDismiss = { showSettings = false })
            }
        }
    }

    // .fullScreenCover(isPresented: $showNewSession) { NewSessionSheet(…) }
    if (showNewSession) {
        Dialog(
            onDismissRequest = { showNewSession = false },
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            DSHNewSessionSheet(
                initialWorkspaceID = newSessionWorkspaceID,
                onDismiss = { showNewSession = false },
            )
        }
    }

    // .alert("重命名项目", …) — hard-coded Chinese strings kept verbatim.
    if (showRenameWorkspace) {
        AlertDialog(
            onDismissRequest = { showRenameWorkspace = false },
            title = { Text("重命名项目", color = dshPrimary()) },
            text = {
                TextField(
                    value = renameWorkspaceText,
                    onValueChange = { renameWorkspaceText = it },
                    placeholder = { Text("项目名称") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    model.renameWorkspace(renameWorkspaceID, renameWorkspaceText)
                    showRenameWorkspace = false
                }) { Text("保存", color = DSHColors.systemBlue()) }
            },
            dismissButton = {
                TextButton(onClick = { showRenameWorkspace = false }) {
                    Text("取消", color = DSHColors.systemBlue())
                }
            },
            containerColor = DSHColors.systemBackground(),
        )
    }

    // .confirmationDialog("删除项目？", titleVisibility: .visible, …)
    if (showDeleteWorkspaceConfirmation) {
        val pending = workspacePendingDeletion
        AlertDialog(
            onDismissRequest = { showDeleteWorkspaceConfirmation = false },
            title = { Text("删除项目？", color = dshPrimary()) },
            text = {
                Text(
                    "将删除项目“${pending?.title ?: ""}”并归档其中的 " +
                        "${pending?.sessions?.size ?: 0} 个会话。项目目录和历史记录仍保留在 Mac 上。",
                    color = dshSecondary(),
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pending?.let { model.deleteWorkspace(it) }
                    showDeleteWorkspaceConfirmation = false
                }) { Text("删除并归档会话", color = DSHColors.systemRed()) }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteWorkspaceConfirmation = false }) {
                    Text("取消", color = DSHColors.systemBlue())
                }
            },
            containerColor = DSHColors.systemBackground(),
        )
    }

    // The Swift `.alert("Something went wrong", …)` bound to errorMessage is
    // hoisted to MainActivity's shared DSHErrorAlert (global on Android).
}

// ---------------------------------------------------------------------------
// happyHeader
// ---------------------------------------------------------------------------

/// Happy's navigation bar: a 44pt workspace button, a centred title, and an
/// 88pt filter/settings capsule. The line below the title is deliberately
/// compact: one status dot and the active Mac name.
@Composable
private fun HappyHeader(
    model: DSHAppModel,
    didRefresh: Boolean,
    onNewSession: () -> Unit,
    onNewSessionIn: (DSHWorkspaceOption) -> Unit,
    onRefresh: () -> Unit,
    onShowSettings: () -> Unit,
) {
    var workspaceMenuExpanded by remember { mutableStateOf(false) }
    var filterMenuExpanded by remember { mutableStateOf(false) }

    // Swift `deviceName` — whitespace-trimmed, defaults to "Mac".
    val deviceName = model.machineName.trim().ifEmpty { "Mac" }
    val statusColor = deviceStatusColor(model)
    val statusLabel = deviceStatusAccessibilityLabel(model)

    Box(
        Modifier
            .fillMaxWidth()
            .background(DSHColors.systemBackground().copy(alpha = 0.96f)),
    ) {
        // Title layer — kept in its own full-width Box because the trailing
        // capsule is wider than the leading button; an HStack would shift the
        // title left (see the Swift comment).
        Column(
            Modifier
                .fillMaxWidth()
                .align(Alignment.Center)
                .clearAndSetSemantics {
                    contentDescription = "$deviceName, $statusLabel"
                },
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            Text(
                DSHLocalization.string("Sessions"),
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = dshPrimary(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(
                    Modifier
                        .size(6.dp)
                        .clip(CircleShape)
                        .background(statusColor),
                )
                Text(deviceName, fontSize = 11.sp, fontWeight = FontWeight.Medium, color = dshSecondary())
            }
        }

        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp)
                .padding(bottom = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Leading 44pt circular workspace menu — square.grid.3x3.fill
            Box {
                Box(
                    Modifier
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(DSHColors.secondarySystemBackground())
                        .border(0.75.dp, dshPrimary().copy(alpha = 0.14f), CircleShape)
                        .clickableRow { workspaceMenuExpanded = true },
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.Apps, // square.grid.3x3.fill
                        DSHLocalization.string("Workspace menu"),
                        20,
                    )
                }
                DSHDropdownMenu(
                    expanded = workspaceMenuExpanded,
                    onDismissRequest = { workspaceMenuExpanded = false },
                    width = 260.dp,
                ) {
                    DSHMenuRow(
                        icon = Icons.Filled.Add, // plus
                        text = DSHLocalization.string("New session"),
                        onClick = { workspaceMenuExpanded = false; onNewSession() },
                    )
                    DSHMenuRow(
                        icon = Icons.Filled.Refresh, // arrow.clockwise
                        text = DSHLocalization.string("Refresh"),
                        onClick = { workspaceMenuExpanded = false; onRefresh() },
                    )
                    if (model.workspaces.isNotEmpty()) {
                        DSHMenuDivider()
                        DSHMenuSectionHeader(DSHLocalization.string("New session in"))
                        for (workspace in model.workspaces) {
                            DSHMenuRow(
                                icon = Icons.Filled.Folder, // folder
                                text = workspace.name,
                                onClick = {
                                    workspaceMenuExpanded = false
                                    onNewSessionIn(workspace)
                                },
                            )
                        }
                    }
                    DSHMenuDivider()
                    DSHMenuRow(
                        icon = Icons.Filled.Settings, // gearshape
                        text = DSHLocalization.string("Settings"),
                        onClick = { workspaceMenuExpanded = false; onShowSettings() },
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            // 88pt filter/settings capsule.
            Row(
                Modifier
                    .size(width = 88.dp, height = 44.dp)
                    .clip(CircleShape)
                    .background(DSHColors.secondarySystemBackground())
                    .border(0.75.dp, dshPrimary().copy(alpha = 0.14f), CircleShape),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box {
                    Box(
                        Modifier
                            .size(width = 44.dp, height = 44.dp)
                            .clickableRow { filterMenuExpanded = true },
                        contentAlignment = Alignment.Center,
                    ) {
                        DSHLocalIcon(
                            if (didRefresh) Icons.Filled.Check
                            else Icons.AutoMirrored.Filled.Sort, // checkmark / line.3.horizontal.decrease
                            DSHLocalization.string("Filter sessions"),
                            19,
                        )
                    }
                    DSHDropdownMenu(
                        expanded = filterMenuExpanded,
                        onDismissRequest = { filterMenuExpanded = false },
                        width = 260.dp,
                        offsetX = -140, // open toward screen-left from the capsule
                    ) {
                        DSHMenuToggleRow(
                            icon = Icons.Filled.Archive, // archivebox
                            text = DSHLocalization.string("Show archived"),
                            checked = model.showArchivedSessions,
                            onCheckedChange = {
                                filterMenuExpanded = false
                                model.setShowArchived(it)
                            },
                        )
                        DSHMenuDivider()
                        DSHMenuToggleRow(
                            icon = Icons.Filled.GridView, // square.grid.2x2
                            text = DSHLocalization.string("Group by workspace"),
                            checked = model.groupsSessionsByWorkspace,
                            onCheckedChange = {
                                filterMenuExpanded = false
                                model.setGroupsSessionsByWorkspace(it)
                            },
                        )
                        DSHMenuRow(
                            icon = if (model.groupsSessionsByWorkspace) {
                                Icons.AutoMirrored.Filled.List // list.bullet
                            } else {
                                Icons.Filled.Check // checkmark
                            },
                            text = DSHLocalization.string("Flat list"),
                            onClick = {
                                filterMenuExpanded = false
                                model.setGroupsSessionsByWorkspace(false)
                            },
                        )
                        DSHMenuDivider()
                        DSHMenuRow(
                            icon = Icons.Filled.Refresh, // arrow.clockwise
                            text = DSHLocalization.string("Refresh"),
                            onClick = { filterMenuExpanded = false; onRefresh() },
                        )
                    }
                }

                // Divider().frame(height: 22).overlay(primary.opacity(0.16))
                Box(
                    Modifier
                        .width(0.7.dp)
                        .height(22.dp)
                        .background(dshPrimary().copy(alpha = 0.16f)),
                )

                Box(
                    Modifier
                        .size(width = 44.dp, height = 44.dp)
                        .clickableRow(onShowSettings),
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.Settings, // gearshape
                        DSHLocalization.string("Settings"),
                        19,
                    )
                }
            }
        }
    }
}

/**
 * Swift `deviceStatusColor` — a pending approval deliberately outranks the
 * ordinary online state; a failed transport stays red. The English
 * accessibility values are Swift-hardcoded (not localized there either).
 */
@Composable
private fun deviceStatusColor(model: DSHAppModel): Color = when (model.deviceStatus) {
    DSHDeviceStatus.Offline -> DSHColors.systemGray()
    DSHDeviceStatus.Error -> DSHColors.systemRed()
    DSHDeviceStatus.Online -> DSHColors.systemGreen()
    DSHDeviceStatus.ApprovalRequired -> DSHColors.systemYellow()
}

private fun deviceStatusAccessibilityLabel(model: DSHAppModel): String = when (model.deviceStatus) {
    DSHDeviceStatus.Offline -> "Offline"
    DSHDeviceStatus.Error -> "Error"
    DSHDeviceStatus.Online -> "Online"
    DSHDeviceStatus.ApprovalRequired -> "Permission confirmation required"
}

// ---------------------------------------------------------------------------
// workspaceSection
// ---------------------------------------------------------------------------

@Composable
private fun WorkspaceSection(
    model: DSHAppModel,
    group: DSHSessionGroup,
    openSession: (String) -> Unit,
    onNewSessionIn: (DSHWorkspaceOption?) -> Unit,
    onRefresh: () -> Unit,
    onRename: (DSHSessionGroup) -> Unit,
    onDelete: (DSHSessionGroup) -> Unit,
) {
    val workspace = workspaceOptionFor(group)
    val expanded = !model.isGroupCollapsed(group.id)
    var optionsMenuExpanded by remember { mutableStateOf(false) }

    fun toggle() {
        // Swift toggle(): setGroup(id, collapsed: currentlyExpanded)
        model.setGroup(group.id, collapsed = expanded)
    }

    // Card: secondarySystemBackground, continuous cornerRadius 18, 0.75pt
    // primary@7% border, horizontal 16 / vertical 8 page padding.
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(DSHColors.secondarySystemBackground())
            .border(0.75.dp, dshPrimary().copy(alpha = 0.07f), RoundedCornerShape(18.dp)),
    ) {
        Column(Modifier.fillMaxWidth()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                // folder.fill / folder, .title3 semibold, 34×34 tap area
                Box(
                    Modifier
                        .size(34.dp)
                        .clickableRow(::toggle),
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        if (expanded) Icons.Filled.FolderOpen else Icons.Filled.Folder,
                        DSHLocalization.string(if (expanded) "Collapse project" else "Expand project"),
                        22,
                    )
                }

                Text(
                    group.title.ifEmpty { DSHLocalization.string("Sessions") },
                    fontSize = 17.sp, // .headline.weight(.semibold)
                    fontWeight = FontWeight.SemiBold,
                    color = dshPrimary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier
                        .clickableRow(::toggle)
                        .padding(vertical = 4.dp),
                )

                Spacer(Modifier.weight(1f))

                // "ellipsis" — project options menu
                Box {
                    Box(
                        Modifier
                            .size(36.dp)
                            .clickableRow { optionsMenuExpanded = true },
                        contentAlignment = Alignment.Center,
                    ) {
                        DSHLocalIcon(
                            Icons.Filled.MoreHoriz, // ellipsis
                            DSHLocalization.string("Project options"),
                            18,
                        )
                    }
                    DSHDropdownMenu(
                        expanded = optionsMenuExpanded,
                        onDismissRequest = { optionsMenuExpanded = false },
                        width = 250.dp,
                    ) {
                        DSHMenuRow(
                            icon = Icons.Filled.Add, // plus
                            text = DSHLocalization.string("New session"),
                            onClick = {
                                optionsMenuExpanded = false
                                onNewSessionIn(workspace)
                            },
                        )
                        DSHMenuRow(
                            icon = if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown, // chevron.up / chevron.down
                            text = DSHLocalization.string(
                                if (expanded) "Collapse project" else "Expand project",
                            ),
                            onClick = {
                                optionsMenuExpanded = false
                                toggle()
                            },
                        )
                        DSHMenuRow(
                            icon = Icons.Filled.Refresh, // arrow.clockwise
                            text = DSHLocalization.string("Refresh project"),
                            onClick = {
                                optionsMenuExpanded = false
                                onRefresh()
                            },
                        )
                        DSHMenuRow(
                            icon = Icons.Filled.Edit, // pencil
                            text = DSHLocalization.string("Rename project"),
                            onClick = {
                                optionsMenuExpanded = false
                                onRename(group)
                            },
                        )
                        DSHMenuRow(
                            icon = Icons.Filled.Delete, // trash
                            text = DSHLocalization.string("Delete project"),
                            destructive = true,
                            onClick = {
                                optionsMenuExpanded = false
                                onDelete(group)
                            },
                        )
                        DSHMenuDivider()
                        DSHMenuToggleRow(
                            icon = Icons.Filled.Archive, // archivebox
                            text = DSHLocalization.string("Show archived"),
                            checked = model.showArchivedSessions,
                            onCheckedChange = {
                                optionsMenuExpanded = false
                                model.setShowArchived(it)
                            },
                        )
                    }
                }

                // "square.and.pencil" — new session in this project
                Box(
                    Modifier
                        .size(36.dp)
                        .clickableRow { onNewSessionIn(workspace) },
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.Edit, // square.and.pencil
                        DSHLocalization.string("New session in ${group.title}"),
                        18,
                    )
                }
            }

            if (expanded) {
                // Divider().padding(.horizontal, 14).opacity(0.55)
                HorizontalDivider(
                    modifier = Modifier.padding(horizontal = 14.dp),
                    thickness = 0.7.dp,
                    color = DSHColors.separator().copy(alpha = 0.55f),
                )
                group.sessions.forEachIndexed { index, session ->
                    GroupedSessionRow(
                        session = session,
                        openSession = { openSession(session.id) },
                    )
                    if (index < group.sessions.lastIndex) {
                        // Divider().padding(.horizontal, 20).opacity(0.45)
                        HorizontalDivider(
                            modifier = Modifier.padding(horizontal = 20.dp),
                            thickness = 0.7.dp,
                            color = DSHColors.separator().copy(alpha = 0.45f),
                        )
                    }
                }
            }
        }
    }
}

/** Swift `workspaceOption(for:)`. */
private fun workspaceOptionFor(group: DSHSessionGroup): DSHWorkspaceOption? {
    val first = group.sessions.firstOrNull() ?: return null
    val id = first.workspaceId ?: return null
    val name = first.workspaceName ?: return null
    return DSHWorkspaceOption(id = id, name = name)
}

// ---------------------------------------------------------------------------
// Archived-session affordances
// ---------------------------------------------------------------------------

/// Happy keeps the archive affordance quiet: it only appears when there is
/// something hidden, and it sits below the active project groups.
@Composable
private fun ArchivedSessionsButton(onShow: () -> Unit) {
    // Grouped mode: plain "Show archived" (Swift passes it UNWRAPPED — verbatim).
    Row(
        Modifier
            .fillMaxWidth()
            .clickableRow(onShow)
            .padding(horizontal = 22.dp, vertical = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(Modifier.weight(1f).height(1.dp).background(dshSecondary().copy(alpha = 0.28f)))
        Text("Show archived", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = dshSecondary())
        DSHLocalIcon(Icons.Filled.KeyboardArrowDown, null, 12, tint = dshSecondary()) // chevron.down
        Box(Modifier.weight(1f).height(1.dp).background(dshSecondary().copy(alpha = 0.28f)))
    }
}

/// Flat mode's toggle between showing and hiding archived sessions.
@Composable
private fun FlatShowHideArchivedButton(showArchived: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clickableRow(onToggle)
            .padding(horizontal = 22.dp, vertical = 18.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.weight(1f).height(1.dp).background(dshSecondary().copy(alpha = 0.28f)))
        Text(
            DSHLocalization.string(if (showArchived) "Hide archived" else "Show archived"),
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = dshSecondary(),
        )
        Box(Modifier.weight(1f).height(1.dp).background(dshSecondary().copy(alpha = 0.28f)))
    }
}

// ---------------------------------------------------------------------------
// emptyHomeState
// ---------------------------------------------------------------------------

/// The centre state mirrors Happy's machine-unreachable screen while remaining
/// useful for an archive-only account.
@Composable
private fun EmptyHomeState(
    model: DSHAppModel,
    hasArchivedSessions: Boolean,
    onNewSession: () -> Unit,
    onShowSettings: () -> Unit,
    onShowArchived: () -> Unit,
) {
    val reachable = model.deviceStatus == DSHDeviceStatus.Online ||
        model.deviceStatus == DSHDeviceStatus.ApprovalRequired
    val machine = model.machineName.ifEmpty { "Mac" }
    Box(
        Modifier
            .fillMaxSize()
            .background(DSHColors.systemBackground()),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                // Swift Spacer/minLength top + bottom with .padding(.bottom, 82)
                .padding(bottom = 82.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            EmptyStateIcon(reachable = reachable)
            Spacer(Modifier.height(20.dp))
            Text(
                if (reachable) {
                    DSHLocalization.string("No sessions yet")
                } else {
                    DSHLocalization.format("%@ is unreachable", machine)
                },
                fontSize = 22.sp, // .title2.weight(.semibold)
                fontWeight = FontWeight.SemiBold,
                color = dshPrimary(),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                DSHLocalization.string(
                    if (reachable) "Start one on a connected machine."
                    else "Bring a machine online to start a session.",
                ),
                fontSize = 17.sp, // .body
                color = dshSecondary(),
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(24.dp))
            OutlinedButton(
                onClick = { if (reachable) onNewSession() else onShowSettings() },
            ) {
                Text(
                    DSHLocalization.string(if (reachable) "Start New Session" else "Troubleshoot"),
                    fontSize = 17.sp,
                    color = DSHColors.systemBlue(),
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                )
            }
            if (hasArchivedSessions) {
                TextButton(
                    onClick = onShowArchived,
                    modifier = Modifier.padding(top = 12.dp),
                ) {
                    Text(
                        "Show archived", // Swift passes it unwrapped here too
                        fontSize = 15.sp, // .subheadline.weight(.medium)
                        fontWeight = FontWeight.Medium,
                        color = dshSecondary(),
                    )
                }
            }
        }
    }
}

@Composable
private fun EmptyStateIcon(reachable: Boolean) {
    if (reachable) {
        // bubble.left.and.bubble.right, 56 regular
        DSHLocalIcon(
            Icons.AutoMirrored.Filled.Chat,
            null,
            56,
            tint = dshSecondary(),
        )
    } else {
        // `cloud.slash` is not present in every SF Symbols runtime used by our
        // supported simulators. Build the same glyph from a stable cloud
        // outline and a diagonal stroke so the unreachable state never loses
        // its visual anchor. (Same composite reproduced here.)
        Box(contentAlignment = Alignment.Center, modifier = Modifier.size(width = 80.dp, height = 80.dp)) {
            DSHLocalIcon(
                Icons.Filled.Cloud, // cloud
                null,
                56,
                tint = dshSecondary(),
            )
            Box(
                Modifier
                    .size(width = 4.dp, height = 72.dp)
                    .rotate(-42f) // rotationEffect(.degrees(-42))
                    .background(dshSecondary()),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// homeDock
// ---------------------------------------------------------------------------

/// A compact, always-visible entry point is the part of Happy's home screen
/// that makes starting work feel immediate. It deliberately opens the native
/// New Session sheet on tap, so the first prompt never bypasses the
/// device/workspace/branch/model choices.
@Composable
private fun HomeDock(onNewSession: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(DSHColors.systemBackground().copy(alpha = 0.92f))
            .padding(horizontal = 16.dp)
            .padding(top = 8.dp, bottom = 8.dp),
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(28.dp))
                .background(dshMaterial())
                .border(0.75.dp, dshPrimary().copy(alpha = 0.08f), RoundedCornerShape(28.dp))
                .clickableRow(onNewSession)
                .padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(44.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(Icons.Filled.Add, null, 22) // plus
                }
                // Divider().frame(height: 24).overlay(primary@16) + h 9 padding
                Box(Modifier.padding(horizontal = 9.dp)) {
                    Box(
                        Modifier
                            .width(0.7.dp)
                            .height(24.dp)
                            .background(dshPrimary().copy(alpha = 0.16f)),
                    )
                }
                Text(
                    DSHLocalization.string("Plan, ask, build…"),
                    fontSize = 17.sp,
                    color = dshSecondary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(Modifier.weight(1f))
                Box(
                    Modifier
                        .padding(start = 8.dp) // Spacer(minLength: 8)
                        .size(44.dp)
                        .clip(CircleShape)
                        .background(DSHColors.tertiarySystemBackground()),
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.ArrowUpward, // arrow.up
                        DSHLocalization.string("New session"),
                        17,
                        tint = dshSecondary(),
                    )
                }
            }
        }
    }
}
