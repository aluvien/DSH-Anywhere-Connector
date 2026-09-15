package com.dshanywhere.features.sessions

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AttachFile
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CallMerge
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.CreateNewFolder
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Photo
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.app.DSHDeviceStatus
import com.dshanywhere.app.DSHStagedAttachment
import com.dshanywhere.core.network.DSHConnectionState
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHModelReasoning
import com.dshanywhere.core.protocol.DSHModelSelection
import com.dshanywhere.core.store.DSHWorkspaceOption
import com.dshanywhere.ui.theme.DSHColors
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/// Ported 1:1 from `private struct NewSessionSheet` (SessionListView.swift).
///
/// Presented by [SessionListScreen] in a full-height Dialog (the Swift
/// `.fullScreenCover`). The ZStack backdrop (`.ultraThinMaterial` + tap to
/// dismiss) is reproduced inside [DSHNewSessionSheetBackdrop].

@Composable
internal fun DSHNewSessionSheet(initialWorkspaceID: String?, onDismiss: () -> Unit) {
    val model = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    // MARK: state — mirrors the @State properties of the Swift sheet
    var workspaceID by remember { mutableStateOf(initialWorkspaceID ?: "") }
    var permissionMode by remember { mutableStateOf("workspace-write") }
    // Swift keeps this as @State but nothing ever edits it — constant "新会话".
    val sessionTitle = "新会话"
    var workingDirectory by remember { mutableStateOf("") }
    var branch by remember { mutableStateOf("main") }
    var sessionMode by remember { mutableStateOf("standard") }
    var selectedProvider by remember { mutableStateOf("") }
    var selectedModel by remember { mutableStateOf("") }
    var selectedReasoningEffort by remember { mutableStateOf<String?>(null) }
    var initialPrompt by remember { mutableStateOf("") }
    val initialAttachments = remember { mutableStateListOf<DSHStagedAttachment>() }
    var showInitialCommandMenu by remember { mutableStateOf(false) }

    // MARK: photo / file pickers
    // Swift: `.photosPicker(matching: .images)` + `.fileImporter(
    //        allowedContentTypes: [.data], allowsMultipleSelection: true)`.
    // Images are downsampled (≤ 2048px) and re-encoded as JPEG q82 before
    // staging — the Android counterpart of `optimizedPhotoDataOffMain`.
    val photoLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent(),
    ) { uri ->
        if (uri != null) stagePickedPhoto(context, model, scope, initialAttachments, uri)
    }
    val fileLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenMultipleDocuments(),
    ) { uris ->
        stagePickedFiles(context, initialAttachments, uris)
    }

    // MARK: derived values (Swift computed properties)

    val selectedWorkspace: DSHWorkspaceOption? =
        model.workspaces.firstOrNull { it.id == workspaceID }

    fun selectWorkspace(workspace: DSHWorkspaceOption) {
        workspaceID = workspace.id
        val recent = model.sessions
            .filter { it.workspaceId == workspace.id }
            .maxByOrNull { it.updatedAt }
        if (recent == null) {
            workingDirectory = ""
            branch = "main"
        } else {
            workingDirectory = recent.cwd ?: ""
            val trimmed = recent.branch?.trim().orEmpty()
            branch = trimmed.ifEmpty { "main" }
        }
    }

    LaunchedEffect(Unit) {
        // .onAppear
        if (workspaceID.isEmpty()) {
            model.workspaces.firstOrNull()?.let { selectWorkspace(it) }
        }
        // If the project disappeared between tapping the button and opening
        // the sheet, fall back to the first current workspace.
        if (initialWorkspaceID != null && model.workspaces.none { it.id == workspaceID }) {
            model.workspaces.firstOrNull()?.let { selectWorkspace(it) }
        }
        if (workingDirectory.isEmpty()) {
            val cwd = model.sessions.firstOrNull { it.workspaceId == workspaceID }?.cwd
            if (cwd != null) workingDirectory = cwd
        }
        if (selectedProvider.isEmpty()) {
            model.modelCatalog?.let { catalog ->
                selectedProvider = catalog.default.provider
                selectedModel = catalog.default.model
                selectedReasoningEffort = catalog.default.reasoningEffort
            }
        }
    }

    // .onChange(of: model.machineID) — reset the project choices. Skips the
    // first composition (Swift's onChange never fires for the initial value).
    var lastMachineID by remember { mutableStateOf(model.machineID) }
    LaunchedEffect(model.machineID) {
        if (model.machineID != lastMachineID) {
            lastMachineID = model.machineID
            workspaceID = ""
            workingDirectory = ""
            branch = "main"
        }
    }

    // .onChange(of: model.workspaces)
    LaunchedEffect(model.workspaces) {
        if (workspaceID.isEmpty()) {
            model.workspaces.firstOrNull()?.let { selectWorkspace(it) }
        }
    }

    // Swift: `displayedWorkingDirectory`
    val displayedWorkingDirectory: String = {
        val path = workingDirectory.trim()
        if (path.isEmpty()) {
            selectedWorkspace?.name ?: "选择工作区"
        } else {
            val components = path.split("/").filter { it.isNotEmpty() }
            if (components.size >= 2 && components[0] == "Users") {
                val suffix = components.drop(2).joinToString("/")
                if (suffix.isEmpty()) "~" else "~/$suffix"
            } else {
                path
            }
        }
    }()

    // Swift: `branchOptions`
    val branchOptions: List<String> = {
        val values = model.sessions.asSequence()
            .filter { workspaceID.isEmpty() || it.workspaceId == workspaceID }
            .mapNotNull { it.branch?.trim() }
            .filter { it.isNotEmpty() }
            .toMutableSet()
        values.add("main")
        values.sortedWith { left, right ->
            when {
                left == "main" -> if (right == "main") 0 else -1
                right == "main" -> 1
                else -> left.compareTo(right, ignoreCase = true)
            }
        }
    }()

    val sessionModeLabel: String = when (sessionMode) {
        "ptc" -> "PTC 模式"
        "custom" -> "自建模式"
        else -> "标准模式"
    }

    // Swift: `selectedModelReasoning` / `effectiveReasoningEffort`
    val selectedModelReasoning: DSHModelReasoning? = model.modelCatalog?.let { catalog ->
        val preferred = catalog.groups.firstOrNull { it.id == selectedProvider }
            ?.models?.firstOrNull { it.id == selectedModel }?.reasoning
        preferred ?: catalog.groups.firstNotNullOfOrNull { group ->
            group.models.firstOrNull { it.id == selectedModel }?.reasoning
        }
    }
    val effectiveReasoningEffort: String =
        selectedReasoningEffort
            ?: selectedModelReasoning?.defaultEffort
            ?: selectedModelReasoning?.efforts?.firstOrNull()?.id
            ?: ""

    fun selectedReasoningName(reasoning: DSHModelReasoning): String =
        reasoning.efforts.firstOrNull { it.id == effectiveReasoningEffort }?.name
            ?: effectiveReasoningEffort

    // Swift: `initialModelLabel`
    val initialModelLabel: String = if (selectedModel.isEmpty()) {
        "选择模型"
    } else {
        model.modelLabel(
            DSHModelSelection(
                provider = selectedProvider.ifEmpty { "deepseek" },
                model = selectedModel,
                reasoningEffort = selectedReasoningEffort,
            ),
        )
    }

    val initialPermissionLabel: String = when (permissionMode) {
        "read-only" -> DSHLocalization.string("Read only")
        "danger-full-access" -> DSHLocalization.string("Full access")
        else -> DSHLocalization.string("Workspace write")
    }

    fun appendCommand(command: String, to: String): String {
        val trimmed = to.trim()
        return if (trimmed.isEmpty()) "/$command " else "$to\n/$command "
    }

    fun createSession() {
        if (model.workspaces.isEmpty()) return
        val selection = if (selectedModel.isEmpty()) {
            null
        } else {
            DSHModelSelection(
                provider = selectedProvider.ifEmpty { "deepseek" },
                model = selectedModel,
                reasoningEffort = selectedReasoningEffort,
            )
        }
        model.createSession(
            workspace = selectedWorkspace,
            title = sessionTitle.ifEmpty { "新会话" },
            workingDirectory = workingDirectory,
            branch = branch,
            mode = sessionMode,
            model = selection,
            permissionMode = permissionMode,
            initialPrompt = initialPrompt,
            initialAttachments = initialAttachments.toList(),
        )
        onDismiss()
    }

    // MARK: body
    // ZStack { Rectangle(.ultraThinMaterial).onTapGesture { dismiss() }
    //          VStack { Spacer(minLength: 88); content } }
    Box(
        Modifier
            .fillMaxSize()
            .background(dshMaterial())
            .pointerInput(Unit) { detectTapGestures { onDismiss() } },
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .systemBarsPadding()
                // SwiftUI moves the sheet with the keyboard; imePadding is the
                // closest non-conflicting behaviour.
                .imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.weight(1f).heightIn(min = 88.dp))

            Column(
                Modifier
                    .fillMaxWidth()
                    .widthIn(max = 560.dp)
                    .padding(horizontal = 18.dp)
                    .padding(bottom = 8.dp),
                verticalArrangement = Arrangement.spacedBy(26.dp),
            ) {
                // compactConfiguration
                Column(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp),
                    verticalArrangement = Arrangement.spacedBy(20.dp),
                ) {
                    MachineSelector(model)
                    WorkspaceSelector(model, workspaceID, displayedWorkingDirectory) {
                        selectWorkspace(it)
                    }
                    BranchSelector(branch, branchOptions) { branch = it }
                    ModeSelector(sessionMode, sessionModeLabel) { sessionMode = it }
                }

                if (initialAttachments.isNotEmpty()) {
                    InitialAttachmentStrip(initialAttachments) { attachment ->
                        // Swift: removeAll { $0.id == attachment.id } — identity
                        // match (DSHStagedAttachment has no id on Android).
                        initialAttachments.removeAll { it === attachment }
                    }
                }

                // initialPromptEditor
                DSHSessionsCompactComposer(
                    text = initialPrompt,
                    onTextChange = { initialPrompt = it },
                    placeholder = DSHLocalization.string(
                        "Send a message, / command, @ file or conversation",
                    ),
                    hasAttachments = initialAttachments.isNotEmpty(),
                    onSubmit = { createSession() },
                ) {
                    DSHSessionsQuickActionsMenu(
                        onCommand = { showInitialCommandMenu = true },
                        onPhoto = { photoLauncher.launch("image/*") },
                        onFile = { fileLauncher.launch(arrayOf("*/*")) },
                    )

                    InitialPermissionMenu(permissionMode) { permissionMode = it }

                    Spacer(Modifier.weight(1f))

                    InitialModelMenu(model, selectedProvider, selectedModel) { provider, modelID, effort ->
                        selectedProvider = provider
                        selectedModel = modelID
                        selectedReasoningEffort = effort
                    }

                    selectedModelReasoning?.takeIf { it.efforts.isNotEmpty() }?.let { reasoning ->
                        InitialReasoningMenu(reasoning, effectiveReasoningEffort) { effortID ->
                            selectedReasoningEffort = effortID
                        }
                    }

                    val canSend = initialPrompt.trim().isNotEmpty() || initialAttachments.isNotEmpty()
                    Box(
                        Modifier
                            .size(36.dp)
                            .alpha(if (canSend) 1f else 0.35f)
                            .clickableRow { if (canSend) createSession() },
                        contentAlignment = Alignment.Center,
                    ) {
                        DSHLocalIcon(
                            Icons.Filled.ArrowCircleUp, // arrow.up.circle.fill
                            DSHLocalization.string("Create session"),
                            28,
                            tint = DSHColors.systemBlue(),
                        )
                    }
                }
            }
        }
    }

    // .sheet(isPresented: $showInitialCommandMenu) { CommandMenuSheet(...)
    //                                               .presentationDetents([.medium]) }
    if (showInitialCommandMenu) {
        DSHSessionsCommandMenuSheet(
            onDismiss = { showInitialCommandMenu = false },
            onPhoto = {
                // The Swift CommandMenuSheet embeds a PhotosPicker and closes
                // itself once a selection appears.
                showInitialCommandMenu = false
                photoLauncher.launch("image/*")
            },
            onFile = {
                showInitialCommandMenu = false
                fileLauncher.launch(arrayOf("*/*"))
            },
            onCommand = { command ->
                showInitialCommandMenu = false
                initialPrompt = appendCommand(command, to = initialPrompt)
            },
        )
    }
}

// ---------------------------------------------------------------------------
// Menu label row — Swift `newSessionInfoRow(icon:title:)`
// ---------------------------------------------------------------------------

@Composable
private fun NewSessionInfoRow(icon: ImageVector?, title: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 32.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            DSHLocalIcon(icon, null, 21) // .font(.system(size: 21, weight: .medium))
        }
        Text(
            title,
            fontSize = 18.sp,
            color = dshPrimary(),
            maxLines = 1,
            // Swift uses .truncationMode(.middle); Compose's built-in ellipsis
            // is head/tail only — middle truncation is not reproduced.
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(Modifier.width(0.dp))
    }
}

/** A full-width tappable info row that anchors a pull-down [DSHDropdownMenu]. */
@Composable
private fun DSHSessionsSelectorRow(
    icon: ImageVector?,
    title: String,
    menuExpanded: Boolean,
    onOpenMenu: () -> Unit,
    onDismissMenu: () -> Unit,
    menuContent: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.fillMaxWidth().clickableRow(onOpenMenu)) {
            NewSessionInfoRow(icon, title)
        }
        DSHDropdownMenu(
            expanded = menuExpanded,
            onDismissRequest = onDismissMenu,
            width = 300.dp,
        ) { menuContent() }
    }
}

// ---------------------------------------------------------------------------
// The four compact selectors (Swift: machineSelector / workspaceSelector /
// branchSelector / modeSelector)
// ---------------------------------------------------------------------------

@Composable
private fun MachineSelector(model: com.dshanywhere.app.DSHAppModel) {
    var expanded by remember { mutableStateOf(false) }
    val machineTitle = if (model.machineName.isEmpty()) "Mac" else model.machineName
    DSHSessionsSelectorRow(
        icon = Icons.Filled.Computer, // desktopcomputer
        title = machineTitle,
        menuExpanded = expanded,
        onOpenMenu = { expanded = true },
        onDismissMenu = { expanded = false },
    ) {
        if (model.machines.isEmpty()) {
            // Swift shows a plain Text row in this case.
            Text(
                machineTitle,
                fontSize = 16.sp,
                color = dshPrimary(),
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
            )
        } else {
            for (machine in model.machines) {
                val active = machine.machineId == model.activeMachine?.machineId
                DSHMenuRow(
                    icon = Icons.Filled.Computer, // desktopcomputer
                    checkmark = active,
                    text = machine.machineName,
                    onClick = {
                        expanded = false
                        model.switchMachine(machine)
                    },
                )
            }
        }
    }
}

@Composable
private fun WorkspaceSelector(
    model: com.dshanywhere.app.DSHAppModel,
    workspaceID: String,
    // Swift shows `displayedWorkingDirectory` as the row title — a
    // sheet-computed value, so it is passed in rather than derived here.
    title: String,
    selectWorkspace: (DSHWorkspaceOption) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    DSHSessionsSelectorRow(
        icon = Icons.Filled.Folder, // folder
        title = title,
        menuExpanded = expanded,
        onOpenMenu = { expanded = true },
        onDismissMenu = { expanded = false },
    ) {
        if (model.workspaces.isEmpty()) {
            Text(
                "暂无可用工作区",
                fontSize = 16.sp,
                color = dshPrimary(),
                modifier = Modifier.padding(horizontal = 14.dp, vertical = 11.dp),
            )
        } else {
            for (workspace in model.workspaces) {
                DSHMenuRow(
                    icon = Icons.Filled.Folder, // folder
                    checkmark = workspace.id == workspaceID,
                    text = workspace.name,
                    onClick = {
                        expanded = false
                        selectWorkspace(workspace)
                    },
                )
            }
        }
    }
}

@Composable
private fun BranchSelector(branch: String, branchOptions: List<String>, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    DSHSessionsSelectorRow(
        icon = Icons.Filled.CallMerge, // arrow.triangle.branch
        title = branch.ifEmpty { "不使用工作树" },
        menuExpanded = expanded,
        onOpenMenu = { expanded = true },
        onDismissMenu = { expanded = false },
    ) {
        DSHMenuRow(
            icon = Icons.Filled.CallMerge, // arrow.triangle.branch
            checkmark = branch.isEmpty(),
            text = "不使用工作树",
            onClick = {
                expanded = false
                onSelect("")
            },
        )
        for (option in branchOptions) {
            DSHMenuRow(
                icon = Icons.Filled.CallMerge, // arrow.triangle.branch
                checkmark = branch == option,
                text = option,
                onClick = {
                    expanded = false
                    onSelect(option)
                },
            )
        }
    }
}

@Composable
private fun ModeSelector(sessionMode: String, sessionModeLabel: String, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    DSHSessionsSelectorRow(
        icon = Icons.Filled.Memory, // cpu
        title = sessionModeLabel,
        menuExpanded = expanded,
        onOpenMenu = { expanded = true },
        onDismissMenu = { expanded = false },
    ) {
        // Swift modeButton(_ mode:title:icon:)
        DSHMenuRow(
            icon = Icons.Filled.AutoAwesome, // sparkles
            checkmark = sessionMode == "standard",
            text = "标准模式",
            onClick = { expanded = false; onSelect("standard") },
        )
        DSHMenuRow(
            icon = Icons.Filled.Assignment, // list.clipboard
            checkmark = sessionMode == "ptc",
            text = "PTC 模式",
            onClick = { expanded = false; onSelect("ptc") },
        )
        DSHMenuRow(
            icon = Icons.Filled.Tune, // slider.horizontal.3
            checkmark = sessionMode == "custom",
            text = "自建模式",
            onClick = { expanded = false; onSelect("custom") },
        )
    }
}

// ---------------------------------------------------------------------------
// Composer control menus (Swift: initialPermissionMenu / initialModelMenu /
// initialReasoningMenu inside NewSessionSheet)
// ---------------------------------------------------------------------------

@Composable
private fun InitialPermissionMenu(permissionMode: String, onSelect: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val label = when (permissionMode) {
        "read-only" -> DSHLocalization.string("Read only")
        "danger-full-access" -> DSHLocalization.string("Full access")
        else -> DSHLocalization.string("Workspace write")
    }
    Box {
        Row(
            Modifier
                .clickableRow { expanded = true }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            DSHLocalIcon(Icons.Filled.Shield, null, 20) // checkmark.shield .title3
            Text(label, fontSize = 14.sp, color = dshPrimary(), maxLines = 1)
        }
        DSHDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, width = 240.dp) {
            DSHMenuRow(
                icon = Icons.Filled.Visibility, // eye
                checkmark = permissionMode == "read-only",
                text = DSHLocalization.string("Read only"),
                onClick = { expanded = false; onSelect("read-only") },
            )
            DSHMenuRow(
                icon = Icons.Filled.Folder, // folder
                checkmark = permissionMode == "workspace-write",
                text = DSHLocalization.string("Workspace write"),
                onClick = { expanded = false; onSelect("workspace-write") },
            )
            DSHMenuRow(
                icon = Icons.Filled.LockOpen, // lock.open
                checkmark = permissionMode == "danger-full-access",
                text = DSHLocalization.string("Full access"),
                onClick = { expanded = false; onSelect("danger-full-access") },
            )
        }
    }
}

@Composable
private fun InitialModelMenu(
    model: com.dshanywhere.app.DSHAppModel,
    selectedProvider: String,
    selectedModel: String,
    onSelect: (provider: String, modelID: String, effort: String?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val label = if (selectedModel.isEmpty()) "选择模型" else model.modelLabel(
        DSHModelSelection(
            provider = selectedProvider.ifEmpty { "deepseek" },
            model = selectedModel,
            reasoningEffort = null,
        ),
    )
    Box {
        Row(
            Modifier
                .clickableRow { expanded = true }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            DSHLocalIcon(Icons.Filled.Memory, null, 16) // cpu
            Text(label, fontSize = 14.sp, color = dshPrimary(), maxLines = 1, overflow = TextOverflow.Ellipsis)
            DSHLocalIcon(Icons.Filled.UnfoldMore, null, 11, tint = dshSecondary()) // chevron.up.chevron.down
        }
        DSHDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, width = 280.dp) {
            val catalog = model.modelCatalog
            if (catalog != null) {
                for (group in catalog.groups) {
                    DSHMenuSectionHeader(group.name)
                    for (item in group.models) {
                        DSHMenuRow(
                            icon = Icons.Filled.Memory, // cpu
                            checkmark = selectedModel == item.id,
                            text = item.name,
                            onClick = {
                                expanded = false
                                onSelect(group.id, item.id, item.reasoning?.defaultEffort)
                            },
                        )
                    }
                }
            } else {
                DSHMenuRow(
                    icon = Icons.Filled.Memory,
                    text = "刷新模型列表",
                    onClick = {
                        expanded = false
                        model.sendModelCatalog()
                    },
                )
            }
        }
    }
}

@Composable
private fun InitialReasoningMenu(
    reasoning: DSHModelReasoning,
    effectiveReasoningEffort: String,
    onSelect: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val name = reasoning.efforts.firstOrNull { it.id == effectiveReasoningEffort }?.name
        ?: effectiveReasoningEffort
    Box {
        Row(
            Modifier
                .widthIn(max = 70.dp) // .frame(maxWidth: 70)
                .clickableRow { expanded = true }
                .padding(vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Text(name, fontSize = 14.sp, color = dshPrimary(), maxLines = 1, overflow = TextOverflow.Ellipsis)
            DSHLocalIcon(Icons.Filled.UnfoldMore, null, 11, tint = dshSecondary()) // chevron.up.chevron.down
        }
        DSHDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            width = 220.dp,
            offsetX = (-80), // Swift: `.alignmentGuide(.trailing)` — anchor to
            // the right end of the narrow label; a fixed negative offset keeps
            // the popover on screen.
        ) {
            for (effort in reasoning.efforts) {
                DSHMenuRow(
                    icon = Icons.Filled.Psychology, // brain.head.profile
                    checkmark = effort.id == effectiveReasoningEffort,
                    text = effort.name,
                    onClick = {
                        expanded = false
                        onSelect(effort.id)
                    },
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Attachment chips (Swift: initialAttachmentStrip)
// ---------------------------------------------------------------------------

@Composable
private fun InitialAttachmentStrip(
    attachments: List<DSHStagedAttachment>,
    onDelete: (DSHStagedAttachment) -> Unit,
) {
    LazyRow(
        Modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        items(attachments) { attachment ->
            Row(
                Modifier
                    .background(dshMaterial(), CircleShape) // .thinMaterial in .capsule
                    .padding(start = 8.dp, end = 6.dp, top = 5.dp, bottom = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (attachment.isImage) {
                    val bitmap = remember(attachment) {
                        runCatching {
                            BitmapFactory.decodeByteArray(attachment.data, 0, attachment.data.size)?.asImageBitmap()
                        }.getOrNull()
                    }
                    if (bitmap != null) {
                        Image(
                            bitmap = bitmap,
                            contentDescription = null,
                            modifier = Modifier
                                .size(28.dp)
                                .clip(RoundedCornerShape(6.dp)),
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop, // scaledToFill
                        )
                    }
                }
                DSHLocalIcon(
                    if (attachment.isImage) Icons.Filled.Photo else Icons.Filled.AttachFile, // photo / paperclip
                    null,
                    12,
                    tint = dshPrimary(),
                )
                Text(
                    attachment.name,
                    fontSize = 12.sp, // Label .font(.caption)
                    color = dshPrimary(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    Modifier
                        .size(18.dp)
                        .clickableRow { onDelete(attachment) },
                    contentAlignment = Alignment.Center,
                ) {
                    DSHLocalIcon(
                        Icons.Filled.Cancel, // xmark.circle.fill
                        "删除附件",
                        14,
                        tint = dshSecondary(),
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Picking helpers — Android counterparts of the Swift photo / file importers.
// ---------------------------------------------------------------------------

/**
 * Swift `optimizedPhotoDataOffMain` + `onChange(of: selectedInitialPhoto)`:
 * load the picked photo, downsample to ≤ 2048px, re-encode as JPEG q82, then
 * stage it as `photo.jpg`; any failure sets the hard-coded Chinese error.
 */
private fun stagePickedPhoto(
    context: Context,
    model: com.dshanywhere.app.DSHAppModel,
    scope: kotlinx.coroutines.CoroutineScope,
    attachments: androidx.compose.runtime.snapshots.SnapshotStateList<DSHStagedAttachment>,
    uri: Uri,
) {
    scope.launch(Dispatchers.IO) {
        try {
            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw IllegalStateException("unreadable uri")
            val optimized = downsampleToJpeg(bytes)
            withContext(Dispatchers.Main) {
                attachments.add(DSHStagedAttachment(name = "photo.jpg", data = optimized, isImage = true))
            }
        } catch (_: Exception) {
            withContext(Dispatchers.Main) {
                // Chinese literal — kept as-is from the Swift source.
                model.errorMessage = "无法读取图片，请重试。"
            }
        }
    }
}

/**
 * Swift `.fileImporter(allowedContentTypes: [.data], allowsMultipleSelection:
 * true)`: read raw bytes per URL, image-ext = png/jpg/jpeg/heic, failures are
 * silently skipped.
 */
private fun stagePickedFiles(
    context: Context,
    attachments: androidx.compose.runtime.snapshots.SnapshotStateList<DSHStagedAttachment>,
    uris: List<Uri>,
) {
    for (uri in uris) {
        val bytes = runCatching {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }.getOrNull() ?: continue
        val name = queryDisplayName(context, uri)
            ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "file"
        val ext = name.substringAfterLast('.', "")
        attachments.add(
            DSHStagedAttachment(
                name = name,
                data = bytes,
                isImage = ext.lowercase() in listOf("png", "jpg", "jpeg", "heic"),
            ),
        )
    }
}

private fun queryDisplayName(context: Context, uri: Uri): String? =
    runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

private fun downsampleToJpeg(bytes: ByteArray): ByteArray {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
    var sampleSize = 1
    val longestSide = maxOf(bounds.outWidth, bounds.outHeight)
    while (longestSide / (sampleSize * 2) >= 2048) sampleSize *= 2
    val decodeOptions = BitmapFactory.Options().apply { inSampleSize = sampleSize }
    val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, decodeOptions)
        ?: return bytes
    var bitmap = decoded
    val side = maxOf(bitmap.width, bitmap.height)
    if (side > 2048) {
        val scale = 2048f / side
        bitmap = Bitmap.createScaledBitmap(
            bitmap,
            (bitmap.width * scale).toInt().coerceAtLeast(1),
            (bitmap.height * scale).toInt().coerceAtLeast(1),
            true,
        )
    }
    val out = ByteArrayOutputStream()
    bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
    return out.toByteArray()
}

// ---------------------------------------------------------------------------
// Dead-code helpers — Swift computed views defined inside NewSessionSheet but
// never referenced (leftovers of an earlier full-form design). Ported for the
// "every type, nothing dropped" mandate; they render nothing on their own.
// ---------------------------------------------------------------------------

@Suppress("unused")
@Composable
private fun NewSessionMachineInfo(model: com.dshanywhere.app.DSHAppModel) {
    // Swift `machineInfo`
    Row(
        Modifier.fillMaxWidth().padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        DSHLocalIcon(Icons.Filled.Laptop, null, 28, tint = dshSecondary()) // laptopcomputer
        Column(Modifier.weight(1f)) {
            Text(
                if (model.machineName.isEmpty()) "Mac" else model.machineName,
                fontSize = 17.sp, // .headline
                fontWeight = FontWeight.SemiBold,
                color = dshPrimary(),
            )
            // Swift `machineStatusLabel` / `machineStatusColor` switch on
            // deviceStatus; Chinese literals are hardcoded there too.
            val status = model.deviceStatus
            Text(
                when (status) {
                    DSHDeviceStatus.Offline -> "离线"
                    DSHDeviceStatus.Error -> "连接错误"
                    DSHDeviceStatus.Online -> "已连接"
                    DSHDeviceStatus.ApprovalRequired -> "需要确认权限"
                },
                fontSize = 12.sp, // .caption
                color = when (status) {
                    DSHDeviceStatus.Online -> DSHColors.systemGreen()
                    DSHDeviceStatus.Error -> DSHColors.systemRed()
                    DSHDeviceStatus.ApprovalRequired -> DSHColors.systemYellow()
                    DSHDeviceStatus.Offline -> dshSecondary()
                },
            )
        }
        Spacer(Modifier.weight(1f))
    }
}

@Suppress("unused")
@Composable
private fun NewSessionWorkspaceChooser(
    model: com.dshanywhere.app.DSHAppModel,
    workspaceID: String,
    onSelect: (String) -> Unit,
) {
    // Swift `workspaceChooser`
    var expanded by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Text(
            DSHLocalization.string("Workspace").uppercase(),
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = dshSecondary(),
        )
        if (model.workspaces.isEmpty()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .heightIn(min = 58.dp)
                    .background(DSHColors.secondarySystemBackground(), RoundedCornerShape(18.dp))
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                DSHLocalIcon(Icons.Filled.CreateNewFolder, null, 20, tint = dshSecondary()) // folder.badge.questionmark
                Text(DSHLocalization.string("No workspace is available yet"), fontSize = 17.sp, color = dshSecondary())
                Spacer(Modifier.width(0.dp))
            }
        } else {
            Box(Modifier.fillMaxWidth()) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 58.dp)
                        .clip(RoundedCornerShape(18.dp))
                        .background(DSHColors.secondarySystemBackground())
                        .clickableRow { expanded = true }
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    DSHLocalIcon(Icons.Filled.Folder, null, 20, tint = DSHColors.systemBlue()) // folder.fill .tint
                    Text(
                        model.workspaces.firstOrNull { it.id == workspaceID }?.name
                            ?: DSHLocalization.string("Select workspace"),
                        fontSize = 17.sp,
                        fontWeight = FontWeight.Medium,
                        color = dshPrimary(),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    DSHLocalIcon(Icons.Filled.UnfoldMore, null, 12, tint = dshSecondary()) // chevron.up.chevron.down
                }
                DSHDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, width = 300.dp) {
                    for (workspace in model.workspaces) {
                        DSHMenuRow(
                            icon = Icons.Filled.Folder,
                            checkmark = workspace.id == workspaceID,
                            text = workspace.name,
                            onClick = {
                                expanded = false
                                onSelect(workspace.id)
                            },
                        )
                    }
                }
            }
        }
    }
}

@Suppress("unused")
@Composable
private fun NewSessionModeChooser(
    sessionMode: String,
    permissionMode: String,
    onSessionMode: (String) -> Unit,
    onPermission: (String) -> Unit,
) {
    // Swift `modeChooser`
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Text(
            "模式与权限",
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = dshSecondary(),
        )
        androidx.compose.foundation.layout.Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(DSHColors.secondarySystemBackground()),
        ) {
            SessionModeOption("standard", "标准模式", "适合日常问答与代码任务。", Icons.Filled.AutoAwesome /* sparkles */, sessionMode == "standard") { onSessionMode("standard") }
            SessionModeOption("ptc", "PTC 模式", "先规划，再执行代码任务。", Icons.Filled.Assignment /* list.clipboard */, sessionMode == "ptc") { onSessionMode("ptc") }
            SessionModeOption("custom", "自建模式", "使用本机 Harness 的自定义预设。", Icons.Filled.Tune /* slider.horizontal.3 */, sessionMode == "custom") { onSessionMode("custom") }
            DSHMenuDivider()
            PermissionOption("read-only", "仅可查看", "只能读取工作区内容。", Icons.Filled.Visibility /* eye */, permissionMode == "read-only") { onPermission("read-only") }
            PermissionOption("workspace-write", "工作区内修改", "可以读取并修改所选工作区文件。", Icons.Filled.Folder /* folder */, permissionMode == "workspace-write") { onPermission("workspace-write") }
            PermissionOption("danger-full-access", "完全权限", "可以读写工作区之外的文件。", Icons.Filled.LockOpen /* lock.open */, permissionMode == "danger-full-access") { onPermission("danger-full-access") }
        }
    }
}

@Composable
private fun SessionModeOption(
    mode: String,
    title: String,
    detail: String,
    icon: ImageVector,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    // Swift `sessionModeOption`
    Row(
        Modifier
            .fillMaxWidth()
            .clickableRow(onSelect)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            DSHLocalIcon(
                icon,
                null,
                18,
                tint = if (selected) DSHColors.systemBlue() else dshSecondary(),
            )
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = dshPrimary())
            Text(detail, fontSize = 13.sp, color = dshSecondary())
        }
        DSHLocalIcon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.Circle, // checkmark.circle.fill / circle
            null,
            18,
            tint = if (selected) DSHColors.systemBlue() else dshSecondary(),
        )
    }
}

@Composable
private fun PermissionOption(
    mode: String,
    title: String,
    detail: String,
    icon: ImageVector,
    selected: Boolean,
    onSelect: () -> Unit,
) {
    // Swift `permissionOption`
    Row(
        Modifier
            .fillMaxWidth()
            .clickableRow(onSelect)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.width(28.dp), contentAlignment = Alignment.Center) {
            DSHLocalIcon(icon, null, 18, tint = if (selected) DSHColors.systemBlue() else dshSecondary())
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 16.sp, fontWeight = FontWeight.Medium, color = dshPrimary())
            Text(detail, fontSize = 13.sp, color = dshSecondary())
        }
        DSHLocalIcon(
            if (selected) Icons.Filled.CheckCircle else Icons.Filled.Circle,
            null,
            20,
            tint = if (selected) DSHColors.systemBlue() else dshSecondary(),
        )
    }
}

@Suppress("unused")
@Composable
private fun NewSessionPathAndBranchChooser(
    workingDirectory: String,
    onWorkingDirectory: (String) -> Unit,
    branch: String,
    onBranch: (String) -> Unit,
) {
    // Swift `pathAndBranchChooser`
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Text("项目目录与分支", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = dshSecondary())
        Column(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(16.dp))
                .background(DSHColors.secondarySystemBackground())
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DSHLocalIcon(Icons.Filled.Folder, null, 17, tint = dshSecondary()) // folder
                androidx.compose.foundation.text.BasicTextField(
                    value = workingDirectory,
                    onValueChange = onWorkingDirectory,
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, color = dshPrimary()),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        Box {
                            if (workingDirectory.isEmpty()) {
                                Text("项目目录（可选）", fontSize = 17.sp, color = dshSecondary())
                            }
                            inner()
                        }
                    },
                )
            }
            DSHMenuDivider()
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                DSHLocalIcon(Icons.Filled.CallMerge, null, 17, tint = dshSecondary()) // arrow.triangle.branch
                androidx.compose.foundation.text.BasicTextField(
                    value = branch,
                    onValueChange = onBranch,
                    singleLine = true,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 17.sp, color = dshPrimary()),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        Box {
                            if (branch.isEmpty()) {
                                Text("分支", fontSize = 17.sp, color = dshSecondary())
                            }
                            inner()
                        }
                    },
                )
            }
        }
    }
}
