package com.dshanywhere.features.conversation

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.LocalOnBackPressedDispatcherOwner
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.LaptopMac
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.LocalAppModel
import com.dshanywhere.app.DSHStagedAttachment
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHMessageAttachment
import com.dshanywhere.core.protocol.DSHSessionSummary
import com.dshanywhere.core.protocol.DSHTranscriptEntry
import com.dshanywhere.ui.theme.DSHColors
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * 1:1 Jetpack Compose port of `ConversationView.swift` (the session detail
 * screen): custom 44pt header, interleaved transcript list with bottom-pinned
 * streaming, fixed approval/question cards, the composer and its command,
 * model and permission sheets.
 */
@Composable
fun ConversationScreen(sessionID: String) {
    val model = LocalAppModel.current
    val backDispatcher = LocalOnBackPressedDispatcherOwner.current?.onBackPressedDispatcher
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val focusManager = LocalFocusManager.current

    val listState = rememberLazyListState()

    // SwiftUI @State mirrors.
    var showCommandMenu by remember { mutableStateOf(false) }
    var showModelPicker by remember { mutableStateOf(false) }
    var showPermissionPicker by remember { mutableStateOf(false) }
    var draftAttachments by remember { mutableStateOf(emptyList<DraftAttachment>()) }
    var isSending by remember { mutableStateOf(false) }
    // False once the reader scrolls away from the newest output, so auto-follow
    // never fights a manual scroll (SwiftUI comment).
    var isFollowingLatest by remember { mutableStateOf(true) }

    // Derived model reads (snapshot-observed).
    val session = model.sessions.firstOrNull { it.id == sessionID }
    val transcript = model.transcriptEntriesFor(sessionID)
    val approvals = model.pendingApprovals.filter { it.sessionId == sessionID }
    val questions = model.pendingQuestions.filter { it.sessionId == sessionID }
    val commandResults = model.commandResultsFor(sessionID)
    // SwiftUI: `isRunning = turnState(for:).lowercased() == "running"` — the
    // stop affordance appears only while the Harness reports a running turn.
    val isRunning = model.turnStateFor(sessionID).lowercase() == "running"
    val hasRenderedContent = transcript.isNotEmpty() ||
        commandResults.isNotEmpty() ||
        approvals.isNotEmpty() ||
        questions.isNotEmpty()

    val trimmedTitle = session?.title?.trim().orEmpty()
    val conversationTitle =
        if (trimmedTitle.isEmpty()) DSHLocalization.string("New session") else trimmedTitle
    val mode = model.modeLabel(sessionID)
    val workspaceName = session?.workspaceName?.trim().takeUnless { it.isNullOrEmpty() }
    val cwdLeaf = session?.cwd
        ?.split("/")
        ?.filter { it.isNotEmpty() }
        ?.lastOrNull()
        ?.takeUnless { it.isEmpty() }
    val conversationSubtitle = when {
        workspaceName != null -> "$mode · $workspaceName"
        cwdLeaf != null -> "$mode · $cwdLeaf"
        else -> "$mode · DSH Anywhere"
    }

    // `.task(id: sessionID) { model.markSessionRead(sessionID); model.sendModelCatalog() }`
    LaunchedEffect(sessionID) {
        model.markSessionRead(sessionID)
        model.sendModelCatalog()
    }

    // SwiftUI `.onChange(of: model.messages(for: sessionID).count)` — new
    // activity while the conversation is open clears the unread marker again.
    LaunchedEffect(model.messagesFor(sessionID).size) {
        model.markSessionRead(sessionID)
    }

    // SwiftUI `.onChange(of: session?.updatedAt)` — the Connector can bump a
    // session without sending a message (archive, model change, rename).
    LaunchedEffect(session?.updatedAt) {
        model.markSessionRead(sessionID)
    }

    // MARK: send flow (SwiftUI `send()`)
    //
    // Attachments stay entirely local while the composer is being edited; they
    // are uploaded only from send(), after the prompt is confirmed, so
    // cancelling a chip never leaves a remote file (SwiftUI comment).
    fun send() {
        if (isSending) return
        val text = model.draft
        val staged = draftAttachments
        val trimmed = text.trim()
        if (trimmed.isEmpty() && staged.isEmpty()) return

        // Clear the editor immediately so a double tap cannot send the same
        // draft twice; failed uploads restore below.
        model.draft = ""
        draftAttachments = emptyList()

        // Slash input goes through executeCommand (Android port requirement;
        // iOS sends it as prompt text and exposes commands only via the sheet).
        if (trimmed.startsWith("/") && staged.isEmpty()) {
            model.executeCommand(trimmed, sessionID)
            return
        }

        isSending = true
        scope.launch {
            var uploadedCount = 0
            try {
                val receipts = mutableListOf<String>()
                val messageAttachments = mutableListOf<DSHMessageAttachment>()
                for (item in staged) {
                    val receipt = model.uploadAttachmentAndWait(
                        name = item.staged.name,
                        data = item.staged.data,
                        sessionID = sessionID,
                    )
                    receipts += receipt
                    val mediaType = if (item.staged.isImage) "image/jpeg" else null
                    model.cacheAttachmentData(item.staged.data, receipt)
                    messageAttachments += DSHMessageAttachment(
                        id = receipt,
                        name = item.staged.name,
                        mediaType = mediaType,
                        receiptId = receipt,
                    )
                    uploadedCount += 1
                }
                model.sendPrompt(text, receipts, messageAttachments, sessionID)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                model.draft = text
                draftAttachments = staged.drop(uploadedCount)
                model.errorMessage = e.message
            }
            isSending = false
        }
    }

    // MARK: pickers

    val photoLauncher = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            val bytes = optimizedPhotoBytes(context, uri)
            if (bytes != null) {
                draftAttachments += DraftAttachment(
                    id = nextDraftId(),
                    staged = DSHStagedAttachment(name = "photo.jpg", data = bytes, isImage = true),
                )
            } else {
                // A photo that is only in the cloud cannot be read without
                // downloading it first — say so (SwiftUI comment).
                model.errorMessage = DSHLocalization.string(
                    "Could not read that photo. If it is stored in iCloud, open it in Photos once so it downloads, then try again.",
                )
            }
        }
    }

    val fileLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        scope.launch {
            for (uri in uris.orEmpty()) {
                val bytes = runCatching {
                    context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                }.getOrNull() ?: continue
                val name = displayName(context, uri)
                val ext = name.substringAfterLast('.', "").lowercase()
                val isImage = ext in listOf("png", "jpg", "jpeg", "heic")
                draftAttachments += DraftAttachment(
                    id = nextDraftId(),
                    staged = DSHStagedAttachment(name = name, data = bytes, isImage = isImage),
                )
            }
        }
    }

    fun refreshSession() {
        model.refreshSessions(includeArchived = true)
        model.sendModelCatalog()
    }

    fun archiveSession() {
        model.archive(session ?: DSHSessionSummary(id = sessionID, title = "Conversation"), archived = true)
        backDispatcher?.onBackPressed()
    }

    // MARK: bottom-anchored streaming
    //
    // SwiftUI: a 1pt bottom anchor view whose onAppear/onDisappear flips
    // `isFollowingLatest`, plus onChange scroll-to-anchor for message count,
    // entry count and run state. Streaming jumps are *not* animated (SwiftUI
    // comment: animating per token kept Core Animation busy).

    // A content signature that changes whenever the newest row grows, so
    // token-by-token streaming re-pins the viewport even though the row count
    // is stable.
    var streamTick by remember { mutableLongStateOf(0L) }
    val lastEntry = transcript.lastOrNull()
    LaunchedEffect(
        transcript.size,
        approvals.size,
        questions.size,
        hasRenderedContent,
        isRunning,
        lastTailSignature(lastEntry),
    ) {
        streamTick += 1
    }

    LaunchedEffect(listState) {
        snapshotFlow {
            // Bottom = the viewport cannot move forward. Only trust this while
            // the *user* is scrolling: incoming content also momentarily moves
            // the bottom away, and treating that as "scrolled away" would stop
            // auto-follow on the first delta (the classic race).
            val atBottom = !listState.canScrollForward
            val userScrolling = listState.isScrollInProgress
            atBottom to userScrolling
        }
            .distinctUntilChanged()
            .collect { (atBottom, userScrolling) ->
                if (userScrolling) {
                    isFollowingLatest = atBottom
                } else if (atBottom) {
                    isFollowingLatest = true
                }
            }
    }

    // Jump back onto the newest output whenever content changes while pinned.
    LaunchedEffect(streamTick, isFollowingLatest) {
        if (!isFollowingLatest) return@LaunchedEffect
        val last = listState.layoutInfo.totalItemsCount - 1
        if (last >= 0) listState.scrollToItem(last)
    }

    // Viewport height changes (keyboard opening/closing) re-pin too.
    LaunchedEffect(listState) {
        snapshotFlow { listState.layoutInfo.viewportSize.height }
            .distinctUntilChanged()
            .collect {
                if (isFollowingLatest) {
                    val last = listState.layoutInfo.totalItemsCount - 1
                    if (last >= 0) listState.scrollToItem(last)
                }
            }
    }

    // SwiftUI: `.scrollDismissesKeyboard(.interactively)` — the closest
    // Compose behaviour is putting the keyboard away as soon as a drag starts.
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress }
            .distinctUntilChanged()
            .collect { scrolling ->
                if (scrolling) focusManager.clearFocus(force = true)
            }
    }

    // MARK: layout

    // Root Column with `.imePadding()` mirrors `.safeAreaInset(edge: .bottom)`
    // + keyboard avoidance; `navigationBarsPadding()` on the composer covers
    // the gesture bar (task rule 8).
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(DSHColors.systemBackground())
            .imePadding(),
    ) {
        ConversationHeader(
            title = conversationTitle,
            subtitle = conversationSubtitle,
            onBack = { backDispatcher?.onBackPressed() },
            onSelectModel = { showModelPicker = true },
            onPermission = { showPermissionPicker = true },
            onRefresh = { refreshSession() },
            onArchive = { archiveSession() },
        )

        Box(Modifier.weight(1f)) {
            // SwiftUI: .textSelection(.enabled) on message bodies; one
            // SelectionContainer covers the whole transcript. (Note: the old
            // `Modifier.selectionContainer()` extension is gone in this
            // Compose build; the composable wrapper is the live API.)
            SelectionContainer(Modifier.fillMaxSize()) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize(),
                state = listState,
                contentPadding = PaddingValues(16.dp), // LazyVStack .padding()
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Messages and tool calls in one list, ordered by when they
                // arrived (SwiftUI comment).
                items(transcript, key = { it.id }) { entry ->
                    when (entry) {
                        is DSHTranscriptEntry.Turn -> {
                            val block = entry.block
                            if (block.isUserTurn) {
                                MessageBubble(
                                    sessionID = sessionID,
                                    message = block.messages.first(),
                                )
                            } else {
                                AssistantTurnView(
                                    sessionID = sessionID,
                                    block = block,
                                    streaming = isRunning &&
                                        transcript.lastOrNull()?.id == entry.id,
                                )
                            }
                        }

                        is DSHTranscriptEntry.Tool -> {
                            // Kept in place rather than hidden until a turn runs
                            // (SwiftUI comment).
                            ToolActivityCard(tool = entry.tool)
                        }

                        is DSHTranscriptEntry.Command -> {
                            CommandResultCard(result = entry.result)
                        }

                        is DSHTranscriptEntry.ModelChange -> {
                            ModelChangeCard(notice = entry.notice)
                        }
                    }
                }

                items(approvals, key = { "approval-${it.id}" }) { approval ->
                    ApprovalCard(approval = approval) { allow ->
                        model.decide(approval, allow)
                    }
                }

                items(questions, key = { "question-${it.id}" }) { question ->
                    QuestionCard(request = question) { answers ->
                        model.answer(question, answers)
                    }
                }

                if (!hasRenderedContent) {
                    item(key = "empty") {
                        EmptyConversationState(
                            machine = model.machineName.ifEmpty { "Mac" },
                            path = session?.cwd?.let { displayPath(it) } ?: conversationSubtitle,
                        )
                    }
                }

                // The bottom anchor row; its key is referenced nowhere else.
                item(key = "conversation-bottom") {
                    Spacer(Modifier.height(1.dp))
                }
            }
            }

            // Only while the reader is away from the newest output (SwiftUI
            // comment); the jump itself *is* animated. BoxScope.AnimatedVisibility
            // places via the `alignment` parameter (Modifier.align is BoxScope-only).
            Column(
                modifier = Modifier
                    .align(Alignment.BottomEnd)
                    .padding(end = 16.dp, bottom = 12.dp),
                horizontalAlignment = Alignment.End,
            ) {
            AnimatedVisibility(
                visible = !isFollowingLatest,
                enter = fadeIn() + scaleIn(initialScale = 0.8f),
                exit = fadeOut() + scaleOut(targetScale = 0.8f),
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .shadow(elevation = 3.dp, shape = CircleShape, clip = false)
                        .background(MaterialTheme.colorScheme.primary, CircleShape)
                        .clickable {
                            isFollowingLatest = true
                            scope.launch {
                                val last = listState.layoutInfo.totalItemsCount - 1
                                if (last >= 0) listState.animateScrollToItem(last)
                            }
                        }
                        .semantics {
                            contentDescription = DSHLocalization.string("Jump to latest output")
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    // arrow.down.circle.fill, palette (white, accent)
                    Icon(
                        Icons.Filled.ArrowDownward,
                        contentDescription = null,
                        modifier = Modifier.size(20.dp),
                        tint = androidx.compose.ui.graphics.Color.White,
                    )
                }
            }
        }
            }

        ConversationComposerSection(
            sessionID = sessionID,
            session = session,
            draftAttachments = draftAttachments,
            hasRenderedContent = hasRenderedContent,
            isSending = isSending,
            isRunning = isRunning,
            onSend = { send() },
            onCancelTurn = { model.cancelTurn(sessionID) },
            onCommands = { showCommandMenu = true },
            onPhoto = { photoLauncher.launch("image/*") },
            onFile = { fileLauncher.launch(arrayOf("*/*")) },
            onRemoveAttachment = { id ->
                draftAttachments = draftAttachments.filterNot { it.id == id }
            },
            modifier = Modifier.navigationBarsPadding(),
        )
    }

    // MARK: sheets

    if (showCommandMenu) {
        CommandMenuSheet(
            onPhoto = {
                // Picking a photo closes the sheet (SwiftUI onChange path).
                showCommandMenu = false
                photoLauncher.launch("image/*")
            },
            onFile = {
                showCommandMenu = false
                fileLauncher.launch(arrayOf("*/*"))
            },
            onCommand = { command ->
                showCommandMenu = false
                when (command) {
                    "permission" -> showPermissionPicker = true
                    "model" -> showModelPicker = true
                    else -> model.executeCommand("/$command", sessionID)
                }
            },
            onDismiss = { showCommandMenu = false },
        )
    }
    if (showModelPicker) {
        ModelPickerSheet(sessionID = sessionID, onDismiss = { showModelPicker = false })
    }
    if (showPermissionPicker) {
        PermissionPickerSheet(sessionID = sessionID, onDismiss = { showPermissionPicker = false })
    }
}

// MARK: - Header

/**
 * SwiftUI: `happyConversationHeader` — glass back circle, title/subtitle pill,
 * gear menu (Select model / Permission / Refresh / Archive). The native nav bar
 * is hidden, so this 44pt row is the whole toolbar.
 */
@Composable
private fun ConversationHeader(
    title: String,
    subtitle: String,
    onBack: () -> Unit,
    onSelectModel: () -> Unit,
    onPermission: () -> Unit,
    onRefresh: () -> Unit,
    onArchive: () -> Unit,
) {
    var menuExpanded by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 16.dp)
            .padding(top = 4.dp, bottom = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        GlassCircleButton(
            icon = Icons.AutoMirrored.Filled.KeyboardArrowLeft, // chevron.left
            label = DSHLocalization.string("Back"),
            iconSize = 20,
            onClick = onBack,
        )

        Spacer(Modifier.weight(1f).widthIn(min = 0.dp))

        Column(
            modifier = Modifier
                .widthIn(max = 210.dp)
                .heightIn(min = 44.dp)
                .clip(CircleShape)
                .background(DSHColors.thinMaterial())
                .border(0.75.dp, DSHColors.label().copy(alpha = 0.14f), CircleShape)
                .padding(horizontal = 14.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                title,
                style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitle,
                style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Normal),
                color = DSHColors.secondaryLabel(),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        Spacer(Modifier.weight(1f).widthIn(min = 0.dp))

        Box {
            GlassCircleButton(
                icon = Icons.Filled.Settings, // gearshape
                label = DSHLocalization.string("Session settings"),
                iconSize = 19,
                onClick = { menuExpanded = true },
            )
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Filled.Memory, contentDescription = null) }, // cpu
                    text = { Text(DSHLocalization.string("Select model")) },
                    onClick = {
                        menuExpanded = false
                        onSelectModel()
                    },
                )
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Filled.Shield, contentDescription = null) }, // checkmark.shield
                    text = { Text(DSHLocalization.string("Permission")) },
                    onClick = {
                        menuExpanded = false
                        onPermission()
                    },
                )
                DropdownMenuItem(
                    leadingIcon = { Icon(Icons.Filled.Refresh, contentDescription = null) }, // arrow.clockwise
                    text = { Text(DSHLocalization.string("Refresh session info")) },
                    onClick = {
                        menuExpanded = false
                        onRefresh()
                    },
                )
                HorizontalDivider()
                DropdownMenuItem(
                    leadingIcon = {
                        Icon(
                            Icons.Filled.Archive, // archivebox
                            contentDescription = null,
                            tint = DSHColors.systemRed(),
                        )
                    },
                    text = {
                        Text(DSHLocalization.string("Archive session"), color = DSHColors.systemRed())
                    },
                    onClick = {
                        menuExpanded = false
                        onArchive()
                    },
                )
            }
        }
    }
}

/** A 44pt `.ultraThinMaterial` circle with the 0.75pt primary-14% stroke. */
@Composable
private fun GlassCircleButton(
    icon: ImageVector,
    label: String,
    iconSize: Int,
    onClick: () -> Unit,
) {
    Box(
        modifier = Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(DSHColors.thinMaterial())
            .border(0.75.dp, DSHColors.label().copy(alpha = 0.14f), CircleShape)
            .clickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, modifier = Modifier.size(iconSize.dp))
    }
}

// MARK: - Empty state

/**
 * SwiftUI: `emptyConversationState` — intentionally sparse: laptop, machine,
 * path, then two centred lines.
 */
@Composable
private fun EmptyConversationState(machine: String, path: String) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 500.dp)
            .semantics {
                contentDescription = "${DSHLocalization.string("No messages yet")}. $machine"
            },
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.LaptopMac, // laptopcomputer
            contentDescription = null,
            modifier = Modifier
                .size(72.dp) // .font(.system(size: 72))
                .padding(bottom = 14.dp),
            tint = DSHColors.secondaryLabel(),
        )
        Text(
            machine,
            style = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.SemiBold),
            modifier = Modifier.padding(bottom = 4.dp),
        )
        Text(
            path,
            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal),
            color = DSHColors.secondaryLabel(),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier
                .padding(horizontal = 28.dp)
                .padding(bottom = 40.dp),
        )
        Text(
            DSHLocalization.string("No messages yet"),
            style = TextStyle(fontSize = 20.sp, fontWeight = FontWeight.Normal),
            color = DSHColors.secondaryLabel(),
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(bottom = 8.dp),
        )
        Text(
            DSHLocalization.string("Created just now"),
            style = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal),
            color = DSHColors.secondaryLabel(),
            textAlign = TextAlign.Center,
        )
    }
}

// MARK: - Streaming signature

/**
 * A length signature of the newest transcript row: streaming mutates the last
 * entry in place without changing the row count, so the auto-follow effect has
 * to watch content size, not just list size.
 */
private fun lastTailSignature(entry: DSHTranscriptEntry?): Long = when (entry) {
    is DSHTranscriptEntry.Turn ->
        entry.block.visibleMessages.sumOf { it.markdown.length.toLong() } +
            entry.block.reasoning.length.toLong()
    is DSHTranscriptEntry.Tool ->
        entry.tool.status.length.toLong() + (entry.tool.detail?.length?.toLong() ?: 0L)
    is DSHTranscriptEntry.Command ->
        entry.result.text?.length?.toLong() ?: 0L
    is DSHTranscriptEntry.ModelChange ->
        entry.notice.current.model.length.toLong()
    null -> 0L
}

// MARK: - Path & attachment helpers

/**
 * SwiftUI: `displayPath(_:)` — collapse the conventional `/Users/<name>`
 * prefix without reading the Mac's filesystem from the phone.
 */
private fun displayPath(raw: String): String {
    val components = raw.split("/").filter { it.isNotEmpty() }
    if (components.size < 2 || components.first() != "Users") return raw
    val suffix = components.drop(2).joinToString("/")
    return if (suffix.isEmpty()) "~" else "~/$suffix"
}

/** Monotonic-ish local id for staged chips (SwiftUI uses UUID()). */
private val nextDraftIdSeed = java.util.concurrent.atomic.AtomicLong(0)
private fun nextDraftId(): Long =
    System.nanoTime() * 16 + nextDraftIdSeed.incrementAndGet() % 16

/**
 * SwiftUI: `optimizedPhotoData` — camera originals are 10–30 MB; downsample to
 * 2048 max pixels and re-encode JPEG at quality 0.82 before upload. CPU work
 * stays off the main thread (Task.detached(priority: .userInitiated)).
 */
private suspend fun optimizedPhotoBytes(context: Context, uri: Uri): ByteArray? =
    withContext(Dispatchers.Default) {
        val raw = runCatching {
            context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
        }.getOrNull() ?: return@withContext null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(raw, 0, raw.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return@withContext raw
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= 2048 || bounds.outHeight / (sample * 2) >= 2048) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = BitmapFactory.decodeByteArray(raw, 0, raw.size, options)
            ?: return@withContext raw
        val bitmap = if (decoded.width > 2048 || decoded.height > 2048) {
            val scale = 2048f / maxOf(decoded.width, decoded.height)
            Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * scale).toInt().coerceAtLeast(1),
                (decoded.height * scale).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            decoded
        }
        val out = java.io.ByteArrayOutputStream()
        val ok = bitmap.compress(Bitmap.CompressFormat.JPEG, 82, out)
        if (bitmap !== decoded) decoded.recycle()
        if (bitmap !== decoded) bitmap.recycle()
        if (!ok) raw else out.toByteArray()
    }

/** Resolve a content-uri display name; fall back to the last path segment. */
private fun displayName(context: Context, uri: Uri): String {
    if (uri.scheme == "file") return uri.lastPathSegment ?: "file.bin"
    val name = runCatching {
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (cursor.moveToFirst() && index >= 0) cursor.getString(index) else null
        }
    }.getOrNull()
    return name ?: (uri.lastPathSegment ?: "file.bin")
}
