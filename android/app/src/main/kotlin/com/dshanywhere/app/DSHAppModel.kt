package com.dshanywhere.app

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.dshanywhere.core.network.DSHAPIError
import com.dshanywhere.core.network.DSHConnectionState
import com.dshanywhere.core.network.DSHRemoteProfile
import com.dshanywhere.core.network.DSHRelayDevice
import com.dshanywhere.core.protocol.DSHApprovalRequest
import com.dshanywhere.core.protocol.DSHChatMessage
import com.dshanywhere.core.protocol.DSHCommand
import com.dshanywhere.core.protocol.DSHCommandResult
import com.dshanywhere.core.protocol.DSHEvent
import com.dshanywhere.core.protocol.DSHEventKind
import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.DSHLanguage
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHMessageAttachment
import com.dshanywhere.core.protocol.DSHMessageRole
import com.dshanywhere.core.protocol.DSHModelCatalog
import com.dshanywhere.core.protocol.DSHModelCatalogGroup
import com.dshanywhere.core.protocol.DSHModelCatalogModel
import com.dshanywhere.core.protocol.DSHModelReasoning
import com.dshanywhere.core.protocol.DSHModelReasoningEffort
import com.dshanywhere.core.protocol.DSHModelSelection
import com.dshanywhere.core.protocol.DSHPairingCredential
import com.dshanywhere.core.protocol.DSHQuestionAnswer
import com.dshanywhere.core.protocol.DSHQuestionRequest
import com.dshanywhere.core.protocol.DSHSessionSummary
import com.dshanywhere.core.protocol.DSHSessionUsage
import com.dshanywhere.core.protocol.DSHToolActivity
import com.dshanywhere.core.protocol.DSHTranscriptEntry
import com.dshanywhere.core.protocol.DSHUploadedAttachment
import com.dshanywhere.core.protocol.epochMillisNow
import com.dshanywhere.core.protocol.transcriptEntries
import com.dshanywhere.core.protocol.withTaskTimelines
import com.dshanywhere.core.store.DSHEventReducer
import com.dshanywhere.core.store.DSHProfileStore
import com.dshanywhere.core.store.DSHSessionGroup
import com.dshanywhere.core.store.DSHSessionGrouping
import com.dshanywhere.core.store.DSHStoreState
import com.dshanywhere.core.store.DSHWorkspaceOption
import com.dshanywhere.core.store.groupedForList
import com.dshanywhere.core.store.workspaceOptions
import java.util.Base64
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer

/**
 * One shared interpretation of device reachability for every screen.
 * Relay health and Mac presence are intentionally not conflated.
 */
enum class DSHDeviceStatus { Offline, Error, Online, ApprovalRequired }

/** The reasoning choices exposed by the currently selected Harness model. */
data class DSHReasoningConfiguration(
    val provider: String,
    val model: String,
    val efforts: List<DSHModelReasoningEffort>,
    val selectedEffortID: String,
) {
    val selectedEffort: DSHModelReasoningEffort?
        get() = efforts.firstOrNull { it.id == selectedEffortID }
}

/** An attachment picked in the composer, not yet uploaded. */
class DSHStagedAttachment(
    val name: String,
    val data: ByteArray,
    val isImage: Boolean,
)

/**
 * The observable application model. Mirrors `DSHAppModel` in
 * ios/DSHAnywhere/App/DSHAppModel.swift; every @Published property is a Compose
 * snapshot `mutableStateOf` so views observe it directly.
 */
class DSHAppModel(
    private val context: Context,
    private val transport: DSHAppTransport = DSHRemoteTransport(context),
    initialState: DSHStoreState = DSHStoreState(),
    isPaired: Boolean? = null,
) {
    private val profileStore = DSHProfileStore(context)
    private val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    var state by mutableStateOf(initialState)
        private set
    var isPaired by mutableStateOf(
        isPaired ?: run {
            val t = transport
            if (t is DSHRemoteTransport) t.isConfigured else false
        },
    )
        private set
    var isPairing by mutableStateOf(false)
    var machineID by mutableStateOf("")
    var pairingSecret by mutableStateOf("")
    var serverAddress by mutableStateOf(prefs.getString(KEY_SERVER_ADDRESS, "") ?: "")
    var machineName by mutableStateOf("My Mac")
    var selectedSessionID by mutableStateOf<String?>(null)
    var draft by mutableStateOf("")
    var showArchivedSessions by mutableStateOf(false)

    /** Conversation presentation choices. Local UI preferences only. */
    @set:JvmName("putShowUsageFooter")
    var showUsageFooter by mutableStateOf(prefs.getBoolean(KEY_USAGE_FOOTER, true))
    @set:JvmName("putCollapseComposerControls")
    var collapseComposerControls by mutableStateOf(prefs.getBoolean(KEY_COMPOSER_COLLAPSED, true))

    /** List arrangement and per-section collapse survive relaunch. */
    @set:JvmName("putGroupsSessionsByWorkspace")
    var groupsSessionsByWorkspace by mutableStateOf(prefs.getBoolean(KEY_GROUPING, false))
    var collapsedSessionGroups by mutableStateOf(stringSet(KEY_COLLAPSED_GROUPS))
    var workspaceAliases by mutableStateOf(stringMap(KEY_WORKSPACE_ALIASES))
        private set
    var hiddenWorkspaceIDs by mutableStateOf(stringSet(KEY_HIDDEN_WORKSPACES))
        private set

    /**
     * The Harness bridge has no command for deleting one historical message.
     * Keep a persistent, device-local suppression list.
     */
    var hiddenMessageKeys by mutableStateOf(stringSet(KEY_HIDDEN_MESSAGES))
        private set

    /**
     * Last-read markers, keyed by machine + session. Comparing the session's
     * updatedAt against this is enough to highlight activity that arrived after
     * the user last opened that conversation.
     */
    var lastReadSessionTimestamps by mutableStateOf(loadLastReadSessionTimestamps())
        private set
    private val unreadBaseline: Long = loadOrCreateUnreadBaseline()

    @set:JvmName("putLanguage")
    var language by mutableStateOf(DSHLanguage.fromRaw(prefs.getString(KEY_LANGUAGE, null)))
    var errorMessage by mutableStateOf<String?>(null)

    /** Every Mac this device is paired with. */
    var machines by mutableStateOf(profileStore.profiles)
        private set
    /** Devices paired to the active machine, as the relay reports them. */
    var pairedDevices by mutableStateOf<List<DSHRelayDevice>>(emptyList())
        private set
    /** Kept apart from `errorMessage` so a device-list failure does not alert. */
    var devicesError by mutableStateOf<String?>(null)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private var eventTask: Job? = null
    /**
     * WebSocket deltas can arrive much faster than a phone needs to redraw.
     * Keep the reducer authoritative, but publish one state snapshot per
     * frame-sized window instead of invalidating every view for every token.
     */
    private var pendingEvents = mutableListOf<DSHEvent>()
    private var eventFlushTask: Job? = null
    /** A prompt upload completes before the Harness emits its accepted user message. */
    private var pendingMessageAttachmentsBySession = mutableMapOf<String, MutableList<List<DSHMessageAttachment>>>()
    private var attachmentDataByReceipt = mutableMapOf<String, ByteArray>()
    private val deviceID = "android-device"
    /** The `session.create` request whose reply should open a session, if any. */
    private var awaitingCreatedSession: String? = null
    private var pendingInitialMessagesByRequestID = mutableMapOf<String, PendingInitialMessage>()
    private val lastOpenSessionAt = mutableMapOf<String, Long>()

    private class PendingInitialMessage(val text: String, val attachments: List<DSHStagedAttachment>)

    init {
        profileStore.activeProfile?.let { active ->
            machineName = active.machineName
            machineID = active.machineId
        }
        DSHLocalization.language = language
    }

    /** The Mac the app is currently talking to. */
    val activeMachine: DSHRemoteProfile? get() = profileStore.activeProfile

    val sessions: List<DSHSessionSummary> get() = state.sessions
    val hasLoadedSessions: Boolean get() = state.hasLoadedSessions
    val modelCatalog: DSHModelCatalog? get() = state.modelCatalog
    val modeCatalog get() = state.modeCatalog
    val directoryListing get() = state.directoryListing
    val pendingApprovals: List<DSHApprovalRequest> get() = state.pendingApprovals
    val pendingQuestions: List<DSHQuestionRequest> get() = state.pendingQuestions
    val connectionState: DSHConnectionState get() = state.connectionState
    val isPreparingInitialConnection: Boolean get() = state.isAwaitingInitialSessions

    val deviceStatus: DSHDeviceStatus
        get() {
            when (val transport = state.transportState) {
                is DSHConnectionState.Failed -> return DSHDeviceStatus.Error
                is DSHConnectionState.Reconnecting -> if (transport.attempt >= 3) return DSHDeviceStatus.Error
                else -> Unit
            }
            if (state.transportState != DSHConnectionState.Connected || !state.machineOnline) {
                return DSHDeviceStatus.Offline
            }
            if (state.bridgeReachable == false) return DSHDeviceStatus.Error
            if (state.bridgeReachable == null) return DSHDeviceStatus.Offline
            return if (state.pendingApprovals.isEmpty()) DSHDeviceStatus.Online
            else DSHDeviceStatus.ApprovalRequired
        }

    fun isSessionUnread(session: DSHSessionSummary): Boolean {
        if (session.archived == true || session.updatedAt <= 0) return false
        val lastRead = lastReadSessionTimestamps[sessionReadKey(session.id)] ?: unreadBaseline
        return session.updatedAt > lastRead
    }

    fun markSessionRead(sessionID: String) {
        val sessionTimestamp = sessions.firstOrNull { it.id == sessionID }?.updatedAt ?: 0
        val now = epochMillisNow()
        val value = maxOf(sessionTimestamp, now)
        val key = sessionReadKey(sessionID)
        if (lastReadSessionTimestamps[key] == value) return
        lastReadSessionTimestamps = lastReadSessionTimestamps + (key to value)
        prefs.edit().putString(
            KEY_LAST_READ_SESSIONS,
            DSHJson.encodeToString(
                MapSerializer(String.serializer(), Long.serializer()),
                lastReadSessionTimestamps,
            ),
        ).apply()
    }

    private fun sessionReadKey(sessionID: String): String = "$machineID\u001F$sessionID"

    private fun loadLastReadSessionTimestamps(): Map<String, Long> {
        val raw = prefs.getString(KEY_LAST_READ_SESSIONS, null) ?: return emptyMap()
        return runCatching {
            DSHJson.decodeFromString(MapSerializer(String.serializer(), Long.serializer()), raw)
        }.getOrDefault(emptyMap())
    }

    private fun loadOrCreateUnreadBaseline(): Long {
        val stored = prefs.getLong(KEY_UNREAD_BASELINE, 0L)
        if (stored != 0L) return stored
        val now = epochMillisNow()
        prefs.edit().putLong(KEY_UNREAD_BASELINE, now).apply()
        return now
    }

    fun messagesFor(sessionID: String): List<DSHChatMessage> =
        state.messagesBySession[sessionID] ?: emptyList()

    fun toolsFor(sessionID: String): List<DSHToolActivity> =
        state.toolsBySession[sessionID] ?: emptyList()

    /** The transcript in the order things actually happened. */
    fun transcriptEntriesFor(sessionID: String): List<DSHTranscriptEntry> =
        messagesFor(sessionID)
            .filter { !hiddenMessageKeys.contains(messageKey(sessionID, it.id)) }
            .transcriptEntries(
                tools = toolsFor(sessionID),
                commandResults = commandResultsFor(sessionID),
                modelChanges = modelChangesFor(sessionID),
            )
            .withTaskTimelines()

    /** Hides one message on this device; does not mutate the Mac's history. */
    fun hideMessage(messageID: String, sessionID: String) {
        hiddenMessageKeys = hiddenMessageKeys + messageKey(sessionID, messageID)
        prefs.edit().putStringSet(KEY_HIDDEN_MESSAGES, hiddenMessageKeys).apply()
    }

    private fun messageKey(sessionID: String, messageID: String): String =
        "$machineID\u001F$sessionID\u001F$messageID"

    fun modelChangesFor(sessionID: String) =
        state.modelChangesBySession[sessionID] ?: emptyList()

    fun turnStateFor(sessionID: String): String =
        state.turnStateBySession[sessionID] ?: "idle"

    fun usageFor(sessionID: String): DSHSessionUsage? =
        state.usageBySession[sessionID]
            ?: sessions.firstOrNull { it.id == sessionID }?.usage

    fun permissionModeFor(sessionID: String): String =
        state.permissionBySession[sessionID]?.mode
            ?: sessions.firstOrNull { it.id == sessionID }?.permissionMode
            ?: "workspace-write"

    fun commandResultsFor(sessionID: String) =
        state.commandResultsBySession[sessionID] ?: emptyList()

    fun attachmentsFor(sessionID: String) =
        state.attachmentsBySession[sessionID] ?: emptyList()

    /**
     * Keeps the already-downsampled image available for the current run and on
     * disk for a later session-history reload. Only thumbnail bytes are
     * cached; the original never leaves the device.
     */
    fun cacheAttachmentData(data: ByteArray, receiptId: String) {
        attachmentDataByReceipt[receiptId] = data
        val url = java.io.File(attachmentCacheDir, cacheFileName(receiptId))
        scope.launch(Dispatchers.IO) {
            runCatching {
                url.parentFile?.mkdirs()
                url.writeBytes(data)
            }
            // A cache miss only removes the thumbnail; the Harness file and
            // the message itself remain intact.
        }
    }

    fun attachmentData(attachment: DSHMessageAttachment): ByteArray? {
        val key = attachment.receiptId ?: attachment.id
        attachmentDataByReceipt[key]?.let { return it }
        val url = java.io.File(attachmentCacheDir, cacheFileName(key))
        val data = runCatching { if (url.exists()) url.readBytes() else null }.getOrNull() ?: return null
        attachmentDataByReceipt[key] = data
        return data
    }

    /** Drops a staged upload before the message goes out. */
    fun discardAttachment(id: String, sessionID: String) {
        val values = state.attachmentsBySession[sessionID] ?: return
        state = state.copy(
            attachmentsBySession = state.attachmentsBySession +
                (sessionID to values.filterNot { it.id == id }),
        )
    }

    private fun cacheFileName(key: String): String =
        Base64.getEncoder().encodeToString(key.toByteArray(Charsets.UTF_8))
            .replace('/', '_')
            .replace('+', '-')
            .replace("=", "")

    // MARK: - Pairing & machines

    fun pair() {
        val trimmedMachineID = machineID.trim()
        val trimmedSecret = pairingSecret.trim()
        val address = serverAddress.trim()
        if (trimmedMachineID.isEmpty()) {
            errorMessage = DSHLocalization.string("Enter the machine ID shown by DSH Anywhere Connector.")
            return
        }
        // One field accepts either shape: an 8-character one-time code or the
        // longer pairing secret, distinguished by length.
        val credential = DSHPairingCredential.detect(trimmedSecret)
        if (credential == null) {
            errorMessage = DSHLocalization.string("Enter the pairing code or secret shown by DSH Anywhere Connector.")
            return
        }
        if (address.isEmpty()) {
            errorMessage = "Enter the HTTPS address for your DSH Anywhere gateway."
            return
        }
        isPairing = true
        scope.launch {
            try {
                val profile = transport.pair(address, trimmedMachineID, credential, "Android")
                prefs.edit().putString(KEY_SERVER_ADDRESS, address).apply()
                machineName = profile.machineName
                machineID = profile.machineId
                refreshMachines()
                isPaired = true
                connect()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message
            } finally {
                isPairing = false
            }
        }
    }

    private fun refreshMachines() {
        machines = profileStore.profiles
    }

    /** Points the app at another paired Mac; the old socket is torn down. */
    fun switchMachine(machine: DSHRemoteProfile) {
        if (machine.machineId == activeMachine?.machineId) return
        eventTask?.cancel()
        eventTask = null
        eventFlushTask?.cancel()
        eventFlushTask = null
        pendingEvents.clear()
        scope.launch {
            transport.setActiveMachine(machine.machineId)
            machineName = machine.machineName
            machineID = machine.machineId
            state = DSHStoreState()
            refreshMachines()
            connect()
        }
    }

    fun removeMachine(machine: DSHRemoteProfile) {
        scope.launch {
            try {
                transport.removeMachine(machine.machineId)
            } catch (e: Exception) {
                errorMessage = e.message
            }
            refreshMachines()
            profileStore.activeProfile?.let { active ->
                machineName = active.machineName
                machineID = active.machineId
            }
            isPaired = profileStore.profiles.isNotEmpty()
        }
    }

    /**
     * Loads the device list for the active machine from the relay. The relay
     * refuses this on older builds, so a failure is reported in Settings.
     */
    fun refreshPairedDevices() {
        if (!isPaired) return
        scope.launch {
            try {
                pairedDevices = transport.pairedDevices()
                devicesError = null
            } catch (e: Exception) {
                pairedDevices = emptyList()
                devicesError = e.message
            }
        }
    }

    fun revokeDevice(device: DSHRelayDevice) {
        scope.launch {
            try {
                transport.revokeDevice(device.deviceId)
                refreshPairedDevices()
            } catch (e: Exception) {
                devicesError = e.message
            }
        }
    }

    /** The device id of the phone holding this app, for self-revoke labeling. */
    val currentDeviceId: String? get() = profileStore.activeProfile?.deviceId

    // MARK: - Connection lifecycle

    fun connect() {
        if (!isPaired || eventTask != null) return
        state = state.copy(
            connectionState = DSHConnectionState.Connecting,
            transportState = DSHConnectionState.Connecting,
            machineOnline = false,
            bridgeReachable = null,
        )
        eventTask = scope.launch {
            try {
                transport.connect().collect { event ->
                    enqueue(event)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                flushPendingEvents()
                errorMessage = e.message
                state = state.copy(
                    transportState = DSHConnectionState.Failed(e.message ?: ""),
                    machineOnline = false,
                    bridgeReachable = null,
                    connectionState = DSHConnectionState.Failed(e.message ?: ""),
                )
            }
            flushPendingEvents()
            eventTask = null
        }
    }

    fun disconnect() {
        eventTask?.cancel()
        eventTask = null
        eventFlushTask?.cancel()
        eventFlushTask = null
        pendingEvents.clear()
        scope.launch { transport.disconnect() }
        state = state.copy(
            transportState = DSHConnectionState.Disconnected,
            machineOnline = false,
            bridgeReachable = null,
            connectionState = DSHConnectionState.Disconnected,
        )
    }

    fun forgetPairing() {
        eventTask?.cancel()
        eventTask = null
        eventFlushTask?.cancel()
        eventFlushTask = null
        pendingEvents.clear()
        scope.launch {
            try {
                transport.forgetPairing()
            } catch (e: Exception) {
                errorMessage = e.message
            }
            state = DSHStoreState()
            isPaired = false
        }
    }

    // MARK: - Sessions & workspaces

    /**
     * Workspaces available when starting a session. Apply the local alias
     * immediately after a rename while the authoritative snapshot is in flight.
     */
    val workspaces: List<DSHWorkspaceOption>
        get() = (state.workspaceCatalog.ifEmpty { sessions.workspaceOptions() }).map { workspace ->
            DSHWorkspaceOption(
                id = workspace.id,
                name = workspaceAliases[workspace.id] ?: workspace.resolvedName,
                path = workspace.path,
            )
        }

    /**
     * Starts a session, optionally inside a workspace.
     *
     * Choosing a workspace matters because a session created without one does
     * not appear in the list at all.
     */
    fun createSession(
        workspace: DSHWorkspaceOption? = null,
        title: String = "新会话",
        workingDirectory: String? = null,
        branch: String? = null,
        mode: String = "standard",
        model: DSHModelSelection? = null,
        permissionMode: String = "workspace-write",
        initialPrompt: String? = null,
        initialAttachments: List<DSHStagedAttachment> = emptyList(),
    ) {
        val known = sessions.map { it.id }.toSet()
        // Remember which request asked for this session. The connector echoes
        // it back as the created event's messageId, which is what lets the
        // reply be matched to this tap instead of guessed at.
        val requestId = UUID.randomUUID().toString()
        awaitingCreatedSession = requestId
        val cleanTitle = title.trim()
        val payload = kotlinx.serialization.json.buildJsonObject {
            put("title", kotlinx.serialization.json.JsonPrimitive(cleanTitle.ifEmpty { "新会话" }))
            workingDirectory?.let {
                val cleanPath = it.trim()
                if (cleanPath.isNotEmpty()) put("workingDirectory", kotlinx.serialization.json.JsonPrimitive(cleanPath))
            }
            workspace?.let { put("workspaceId", kotlinx.serialization.json.JsonPrimitive(it.id)) }
            if (mode.isNotEmpty()) put("agentPreset", kotlinx.serialization.json.JsonPrimitive(mode))
            branch?.let {
                val trimmed = it.trim()
                if (trimmed.isNotEmpty()) put("branch", kotlinx.serialization.json.JsonPrimitive(trimmed))
            }
            model?.let { m ->
                put(
                    "model",
                    kotlinx.serialization.json.buildJsonObject {
                        put("provider", kotlinx.serialization.json.JsonPrimitive(m.provider))
                        put("model", kotlinx.serialization.json.JsonPrimitive(m.model))
                        m.reasoningEffort?.let { put("reasoningEffort", kotlinx.serialization.json.JsonPrimitive(it)) }
                    },
                )
            }
            put("permissionMode", kotlinx.serialization.json.JsonPrimitive(permissionMode))
            // `session.create` can carry plain text, but attachments need a
            // session id before they can be uploaded. When the new-session
            // composer contains files, defer the complete prompt until the
            // matching `session.created` event.
            if (initialAttachments.isEmpty() && initialPrompt != null) {
                val trimmedPrompt = initialPrompt.trim()
                if (trimmedPrompt.isNotEmpty()) {
                    put("initialPrompt", kotlinx.serialization.json.JsonPrimitive(trimmedPrompt))
                }
            }
        }
        if (initialAttachments.isNotEmpty()) {
            pendingInitialMessagesByRequestID[requestId] =
                PendingInitialMessage(initialPrompt ?: "", initialAttachments)
        }
        val command = DSHCommand.new(
            deviceId = deviceID, machineId = machineID, type = "session.create",
            payload = payload, requestId = requestId,
        )
        send(command)
        // Fallback for when `session.created` never arrives (dropped event,
        // older connector): re-request the list and open a session we did not
        // know about. Either path makes the tap do something visible.
        scope.launch {
            delay(1_500)
            if (awaitingCreatedSession != requestId) return@launch
            refreshSessions()
            delay(1_500)
            if (awaitingCreatedSession != requestId) return@launch
            awaitingCreatedSession = null
            val created = sessions.firstOrNull { it.id !in known }
            if (created != null) {
                completeCreatedSession(created, requestId)
            } else {
                pendingInitialMessagesByRequestID.remove(requestId)
            }
        }
    }

    fun refreshSessions(includeArchived: Boolean? = null) {
        val include = includeArchived ?: showArchivedSessions
        send(DSHCommand.listSessions(deviceId = deviceID, machineId = machineID, includeArchived = include))
        send(DSHCommand.workspaceCatalog(deviceID, machineID))
        send(DSHCommand.modeCatalog(deviceID, machineID))
    }

    fun listDirectories(path: String? = null) {
        send(DSHCommand.directoryList(deviceID, machineID, path))
    }

    fun createWorkspace(path: String, title: String? = null) {
        if (path.isBlank()) return
        send(DSHCommand.createWorkspace(deviceID, machineID, path, title))
    }

    /** Session snapshots contain metadata only; opening fetches durable remote history. */
    fun openSession(sessionID: String) {
        val now = epochMillisNow()
        if (now - (lastOpenSessionAt[sessionID] ?: 0L) < 2_000L) return
        lastOpenSessionAt[sessionID] = now
        send(DSHCommand.openSession(
            deviceId = deviceID,
            machineId = machineID,
            sessionId = sessionID,
            streaming = true,
        ))
    }

    fun renameSession(sessionID: String, title: String) {
        val trimmed = title.trim()
        if (trimmed.isEmpty()) return
        val index = state.sessions.indexOfFirst { it.id == sessionID }
        if (index >= 0) {
            val values = state.sessions.toMutableList()
            values[index] = values[index].copy(title = trimmed)
            state = state.copy(sessions = values)
        }
        send(DSHCommand.renameSession(deviceID, machineID, sessionID, trimmed))
    }

    fun sendModelCatalog() {
        send(DSHCommand.modelCatalog(deviceId = deviceID, machineId = machineID))
    }

    fun setShowArchived(value: Boolean) {
        showArchivedSessions = value
        refreshSessions(includeArchived = value)
    }

    val sessionGrouping: DSHSessionGrouping
        get() = if (groupsSessionsByWorkspace) DSHSessionGrouping.ByWorkspace else DSHSessionGrouping.Flat

    fun setLanguage(value: DSHLanguage) {
        language = value
        prefs.edit().putString(KEY_LANGUAGE, value.rawValue).apply()
        // Plain strings built in helpers resolve immediately; the composition
        // reads DSHLocalization.language as snapshot state.
        DSHLocalization.language = value
    }

    fun setGroupsSessionsByWorkspace(value: Boolean) {
        groupsSessionsByWorkspace = value
        prefs.edit().putBoolean(KEY_GROUPING, value).apply()
    }

    fun setShowUsageFooter(value: Boolean) {
        showUsageFooter = value
        prefs.edit().putBoolean(KEY_USAGE_FOOTER, value).apply()
    }

    fun setCollapseComposerControls(value: Boolean) {
        collapseComposerControls = value
        prefs.edit().putBoolean(KEY_COMPOSER_COLLAPSED, value).apply()
    }

    fun isGroupCollapsed(id: String): Boolean = collapsedSessionGroups.contains(id)

    fun setGroup(id: String, collapsed: Boolean) {
        collapsedSessionGroups =
            if (collapsed) collapsedSessionGroups + id else collapsedSessionGroups - id
        prefs.edit().putStringSet(KEY_COLLAPSED_GROUPS, collapsedSessionGroups).apply()
    }

    fun workspaceDisplayNameFor(id: String, fallback: String): String =
        workspaceAliases[id] ?: fallback

    /**
     * Project mutations go to the Harness workspace registry and are applied
     * optimistically to this device's presentation cache.
     */
    fun renameWorkspace(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        workspaceAliases = workspaceAliases + (id to trimmed)
        prefs.edit().putString(KEY_WORKSPACE_ALIASES, encodeStringMap(workspaceAliases)).apply()
        send(DSHCommand.renameWorkspace(deviceId = deviceID, machineId = machineID, workspaceId = id, title = trimmed))
    }

    fun deleteWorkspace(group: DSHSessionGroup) {
        hiddenWorkspaceIDs = hiddenWorkspaceIDs + group.id
        prefs.edit().putStringSet(KEY_HIDDEN_WORKSPACES, hiddenWorkspaceIDs).apply()
        send(DSHCommand.deleteWorkspace(deviceId = deviceID, machineId = machineID, workspaceId = group.id))
    }

    fun archive(session: DSHSessionSummary, archived: Boolean = true) {
        send(DSHCommand.archiveSession(deviceId = deviceID, machineId = machineID, sessionId = session.id, archived = archived))
    }

    // MARK: - Conversation commands

    fun sendPrompt(text: String, sessionID: String) {
        sendPrompt(text, attachments = emptyList(), sessionID = sessionID)
    }

    fun sendPrompt(
        text: String,
        attachments: List<String>,
        messageAttachments: List<DSHMessageAttachment> = emptyList(),
        sessionID: String,
    ) {
        val trimmed = text.trim()
        if (trimmed.isEmpty() && attachments.isEmpty()) return
        if (messageAttachments.isNotEmpty()) {
            pendingMessageAttachmentsBySession.getOrPut(sessionID) { mutableListOf() }
                .add(messageAttachments)
        }
        val parts = attachments.map {
            kotlinx.serialization.json.buildJsonObject {
                put("type", kotlinx.serialization.json.JsonPrimitive("file"))
                put("receiptId", kotlinx.serialization.json.JsonPrimitive(it))
            }
        }
        send(DSHCommand.sendPrompt(deviceId = deviceID, machineId = machineID, sessionId = sessionID, text = trimmed, attachments = parts))
    }

    fun selectModel(selection: DSHModelSelection, sessionID: String) {
        send(DSHCommand.selectModel(
            deviceId = deviceID, machineId = machineID, sessionId = sessionID,
            provider = selection.provider, model = selection.model,
            reasoningEffort = selection.reasoningEffort,
        ))
    }

    /** Resolves the session's model against the server-provided catalog. */
    fun reasoningConfiguration(sessionID: String): DSHReasoningConfiguration? {
        val catalog = modelCatalog ?: return null
        val session = sessions.firstOrNull { it.id == sessionID }
        val rawModel = session?.model ?: catalog.default.model
        val preferredProvider = session?.provider ?: catalog.default.provider

        val preferredGroup = catalog.groups.firstOrNull { it.id == preferredProvider }
        val preferredMatch = preferredGroup?.let { group ->
            group.models.firstOrNull { modelMatches(it, rawModel) }?.let { group to it }
        }
        val match = preferredMatch ?: catalog.groups.firstNotNullOfOrNull { group ->
            group.models.firstOrNull { modelMatches(it, rawModel) }?.let { group to it }
        }
        val (group, item) = match ?: return null
        val reasoning = item.reasoning ?: return null
        if (reasoning.efforts.isEmpty()) return null

        val selected = session?.reasoningEffort
            ?: reasoning.defaultEffort
            ?: (if (rawModel == catalog.default.model) catalog.default.reasoningEffort else null)
            ?: reasoning.efforts[0].id
        return DSHReasoningConfiguration(
            provider = group.id, model = item.id,
            efforts = reasoning.efforts, selectedEffortID = selected,
        )
    }

    private fun modelMatches(item: DSHModelCatalogModel, rawValue: String): Boolean =
        rawValue == item.id || rawValue == item.name || rawValue.endsWith("/${item.id}")

    fun setPermission(mode: String, sessionID: String) {
        send(DSHCommand.setPermission(deviceId = deviceID, machineId = machineID, sessionId = sessionID, mode = mode))
    }

    fun executeCommand(line: String, sessionID: String) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return
        send(DSHCommand.executeCommand(deviceId = deviceID, machineId = machineID, sessionId = sessionID, line = trimmed))
    }

    fun uploadAttachment(name: String, data: ByteArray, sessionID: String) {
        send(DSHCommand.uploadAttachment(deviceId = deviceID, machineId = machineID, sessionId = sessionID, name = name, data = data))
    }

    /**
     * Uploads one staged attachment and waits until the connector has returned
     * its receipt — the only safe value to put into a subsequent prompt.
     */
    suspend fun uploadAttachmentAndWait(name: String, data: ByteArray, sessionID: String): String {
        if (data.size > 10 * 1024 * 1024) throw AttachmentTooLarge()
        val requestId = UUID.randomUUID().toString()
        val command = DSHCommand.uploadAttachment(
            deviceId = deviceID, machineId = machineID, sessionId = sessionID,
            name = name, data = data, requestId = requestId,
        )
        transport.send(command)
        // A large camera image may need to cross the phone, Relay, Connector,
        // and the local Harness before the receipt comes back; the old 10
        // second window expired while the Connector was still within its
        // legitimate upload deadline, leaving a false timeout.
        repeat(3_000) {
            coroutineContext.ensureActive()
            state.protocolErrorsByRequestID[requestId]?.let { message ->
                throw RemoteCommandError(message)
            }
            state.attachmentsBySession[sessionID]?.firstOrNull { it.requestId == requestId }?.let {
                return it.receiptId
            }
            delay(50)
        }
        throw AttachmentUploadTimeout()
    }

    class AttachmentUploadTimeout :
        Exception(DSHLocalization.string("The attachment upload timed out. Please try again."))

    class AttachmentTooLarge :
        Exception(DSHLocalization.string("Attachments must be 10 MiB or smaller."))

    class RemoteCommandError(message: String) : Exception(message)

    // MARK: - Labels

    /** Just the model, without its provider prefix. */
    fun shortModelName(sessionID: String): String {
        val full = modelDisplayName(sessionID)
        val provider = sessions.firstOrNull { it.id == sessionID }?.provider
            ?: modelCatalog?.default?.provider
            ?: ""
        val model = full.substringAfterLast('/')
        val lowered = "$provider/$full".lowercase()
        if (lowered.contains("deepseek")) {
            if (lowered.contains("v4.1") && lowered.contains("flash")) return "DS V4.1F"
            if (lowered.contains("v4.1") && (lowered.contains("reason") || lowered.contains("r1"))) return "DS V4.1R"
            if (lowered.contains("v4.1")) return "DS V4.1"
            if (lowered.contains("v3")) return "DS V3"
        }
        if (lowered.contains("claude")) {
            if (lowered.contains("opus")) return "Claude Opus"
            if (lowered.contains("sonnet")) return "Claude Sonnet"
            if (lowered.contains("haiku")) return "Claude Haiku"
        }
        if (lowered.contains("gpt-5")) return "GPT-5"
        if (lowered.contains("gpt-4")) return "GPT-4"
        if (lowered.contains("gemini")) return "Gemini"
        return model
    }

    fun modelDisplayName(sessionID: String): String {
        val session = sessions.firstOrNull { it.id == sessionID }
            ?: return modelCatalog?.default?.model ?: DSHLocalization.string("Select model")
        return session.model ?: modelCatalog?.default?.model ?: DSHLocalization.string("Select model")
    }

    /** Human-friendly abbreviations keep the compact composer readable. */
    fun modelLabel(selection: DSHModelSelection, compact: Boolean = true): String {
        if (!compact) return "${selection.provider}/${selection.model}"
        val raw = selection.model
        val lowered = "${selection.provider}/${raw}".lowercase()
        if (lowered.contains("deepseek")) {
            if (lowered.contains("v4.1") && lowered.contains("flash")) return "DS V4.1F"
            if (lowered.contains("v4.1") && lowered.contains("reason")) return "DS V4.1R"
            if (lowered.contains("v4.1")) return "DS V4.1"
            if (lowered.contains("v3")) return "DS V3"
            return "DeepSeek"
        }
        if (lowered.contains("claude")) {
            if (lowered.contains("opus")) return "Claude Opus"
            if (lowered.contains("sonnet")) return "Claude Sonnet"
            if (lowered.contains("haiku")) return "Claude Haiku"
        }
        if (lowered.contains("gpt-4")) return "GPT-4"
        if (lowered.contains("gpt-5")) return "GPT-5"
        if (lowered.contains("gemini")) return "Gemini"
        return raw
    }

    fun modeLabel(sessionID: String): String {
        val value = sessions.firstOrNull { it.id == sessionID }?.mode
            ?: sessions.firstOrNull { it.id == sessionID }?.agentPreset
            ?: "standard"
        return when (value.lowercase()) {
            "ptc", "plan-to-code", "plan_to_code" -> "PTC 模式"
            "custom", "self", "自建", "自建模式" -> "自建模式"
            else -> "标准模式"
        }
    }

    fun cancelTurn(sessionID: String) {
        send(DSHCommand.cancelTurn(deviceId = deviceID, machineId = machineID, sessionId = sessionID))
    }

    fun decide(approval: DSHApprovalRequest, allow: Boolean) {
        send(DSHCommand.decideApproval(
            deviceId = deviceID, machineId = machineID,
            sessionId = approval.sessionId, approvalId = approval.id, allow = allow,
        ))
    }

    fun answer(request: DSHQuestionRequest, answers: List<DSHQuestionAnswer>) {
        if (answers.isEmpty()) return
        send(DSHCommand.answerQuestion(
            deviceId = deviceID, machineId = machineID,
            sessionId = request.sessionId, questionId = request.id, answers = answers,
        ))
    }

    // MARK: - Plumbing

    private fun send(command: DSHCommand) {
        scope.launch {
            try {
                transport.send(command)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errorMessage = e.message
            }
        }
    }

    private fun enqueue(event: DSHEvent) {
        pendingEvents.add(event)
        if (eventFlushTask?.isActive == true) return
        eventFlushTask = scope.launch {
            delay(50)
            flushPendingEvents()
        }
    }

    private fun flushPendingEvents() {
        eventFlushTask?.cancel()
        eventFlushTask = null
        if (pendingEvents.isEmpty()) return
        val events = pendingEvents.toList()
        pendingEvents.clear()

        // Mutate a local copy and assign once: this turns a burst of assistant
        // deltas/tool events into one UI update.
        var next = DSHEventReducer.reduceAll(events, state)
        next = attachPendingMessageThumbnails(next, events)
        state = next

        for (event in events) handleSessionCreated(event)
    }

    private fun attachPendingMessageThumbnails(
        current: DSHStoreState,
        events: List<DSHEvent>,
    ): DSHStoreState {
        var next = current
        for (event in events) {
            val kind = event.kind as? DSHEventKind.UserMessageAccepted ?: continue
            val sessionID = event.envelope.sessionId ?: continue
            val queue = pendingMessageAttachmentsBySession[sessionID] ?: continue
            if (queue.isEmpty()) continue
            val messages = next.messagesBySession[sessionID] ?: continue
            val index = messages.indexOfFirst { it.id == kind.message.id }
            if (index < 0) continue
            val local = queue.removeAt(0)
            if (messages[index].attachments.isEmpty()) {
                val mutable = messages.toMutableList()
                mutable[index] = messages[index].copy(attachments = local)
                next = next.copy(messagesBySession = next.messagesBySession + (sessionID to mutable))
            }
            if (queue.isEmpty()) pendingMessageAttachmentsBySession.remove(sessionID)
        }
        return next
    }

    private val attachmentCacheDir: java.io.File
        get() = java.io.File(context.filesDir, "dsh-anywhere/attachments").apply { mkdirs() }

    private fun handleSessionCreated(event: DSHEvent) {
        val kind = event.kind as? DSHEventKind.SessionCreated ?: return
        // Open the session only when *this* device asked for it; matching the
        // request id prevents unrelated Harness sessions stealing the screen.
        val expected = awaitingCreatedSession ?: return
        if (event.envelope.messageId != expected) return
        completeCreatedSession(kind.session, expected)
    }

    private fun completeCreatedSession(session: DSHSessionSummary, requestID: String) {
        awaitingCreatedSession = null
        selectedSessionID = session.id
        val pending = pendingInitialMessagesByRequestID.remove(requestID) ?: return
        scope.launch { sendInitialMessage(pending, session.id) }
    }

    private suspend fun sendInitialMessage(pending: PendingInitialMessage, sessionID: String) {
        if (pending.attachments.isEmpty()) return
        try {
            val receipts = mutableListOf<String>()
            val messageAttachments = mutableListOf<DSHMessageAttachment>()
            for (attachment in pending.attachments) {
                val receipt = uploadAttachmentAndWait(attachment.name, attachment.data, sessionID)
                receipts.add(receipt)
                val mediaType = if (attachment.isImage) "image/jpeg" else null
                cacheAttachmentData(attachment.data, receipt)
                messageAttachments.add(
                    DSHMessageAttachment(id = receipt, name = attachment.name, mediaType = mediaType, receiptId = receipt),
                )
            }
            sendPrompt(pending.text, receipts, messageAttachments, sessionID)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            errorMessage = e.message
        }
    }

    private fun stringSet(key: String): Set<String> =
        prefs.getStringSet(key, null)?.toSet() ?: emptySet()

    private fun stringMap(key: String): Map<String, String> {
        val raw = prefs.getString(key, null) ?: return emptyMap()
        return runCatching {
            DSHJson.decodeFromString(MapSerializer(String.serializer(), String.serializer()), raw)
        }.getOrDefault(emptyMap())
    }

    private fun encodeStringMap(map: Map<String, String>): String =
        DSHJson.encodeToString(MapSerializer(String.serializer(), String.serializer()), map)

    companion object {
        /**
         * Debug fixtures mirroring `DSHAppModel.preview()` on iOS: a stable,
         * offline dataset for visual QA through the preview transport.
         */
        fun preview(context: android.content.Context): DSHAppModel {
            val now = System.currentTimeMillis()
            val session = DSHSessionSummary(
                id = "preview-session", title = "Plan the iOS client", updatedAt = now,
                cwd = "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                workspaceId = "preview-dsh", workspaceName = "DSH-ANYWHERE", running = true,
                provider = "deepseek", model = "deepseek-v4.1-flash",
                reasoningEffort = "medium", branch = "main",
            )
            val second = DSHSessionSummary(
                id = "preview-session-2", title = "Debug attachment upload",
                updatedAt = now - 45_000,
                cwd = "/Users/aluvien/Documents/Develop/App/DSH-ANYWHERE",
                workspaceId = "preview-dsh", workspaceName = "DSH-ANYWHERE",
                model = "deepseek-v4.1-flash", branch = "main",
            )
            val third = DSHSessionSummary(
                id = "preview-session-3", title = "Research relay reconnect",
                updatedAt = now - 180_000,
                cwd = "/Users/aluvien/Documents/Develop/App/tihu-test",
                workspaceId = "preview-lab", workspaceName = "tihu-test",
                model = "deepseek-v4.1-flash", branch = "main",
            )
            val efforts = listOf(
                DSHModelReasoningEffort(id = "low", name = "Low"),
                DSHModelReasoningEffort(id = "medium", name = "Medium"),
                DSHModelReasoningEffort(id = "high", name = "High"),
            )
            val state = DSHStoreState(
                sessions = listOf(session, second, third),
                transportState = com.dshanywhere.core.network.DSHConnectionState.Connected,
                machineOnline = true,
                bridgeReachable = true,
                connectionState = com.dshanywhere.core.network.DSHConnectionState.Connected,
                modelCatalog = DSHModelCatalog(
                    default = DSHModelSelection(
                        provider = "deepseek", model = "deepseek-v4.1-flash", reasoningEffort = "medium",
                    ),
                    routableProviders = listOf("deepseek"),
                    groups = listOf(
                        DSHModelCatalogGroup(
                            id = "deepseek", name = "DeepSeek",
                            models = listOf(
                                DSHModelCatalogModel(
                                    id = "deepseek-v4.1-flash", name = "DeepSeek V4.1 Flash",
                                    reasoning = DSHModelReasoning(efforts = efforts, defaultEffort = "medium"),
                                ),
                            ),
                        ),
                    ),
                    failures = emptyList(),
                ),
                messagesBySession = mapOf(
                    session.id to listOf(
                        DSHChatMessage(id = "preview-user", role = DSHMessageRole.user,
                            markdown = "Build a native client for my local Harness."),
                        DSHChatMessage(id = "preview-assistant", role = DSHMessageRole.assistant,
                            markdown = "I can help you plan and implement the native client."),
                    ),
                ),
                toolsBySession = mapOf(
                    session.id to listOf(
                        DSHToolActivity(id = "preview-tool", name = "read_project",
                            status = "completed", detail = "Read 12 files"),
                    ),
                ),
            )
            val model = DSHAppModel(
                context = context, transport = DSHPreviewTransport(),
                initialState = state, isPaired = true,
            )
            model.machineName = "macmini"
            model.selectedSessionID = session.id
            return model
        }

        fun previewHome(context: android.content.Context, grouped: Boolean = false): DSHAppModel {
            val model = preview(context)
            model.selectedSessionID = null
            model.groupsSessionsByWorkspace = grouped
            return model
        }

        /** The disconnected home state, mirroring the iOS DEBUG fixture. */
        fun previewHomeUnreachable(context: android.content.Context): DSHAppModel {
            val model = previewHome(context)
            model.state = model.state.copy(
                sessions = emptyList(),
                hasLoadedSessions = true,
                connectionState = com.dshanywhere.core.network.DSHConnectionState.Failed("macmini is unreachable"),
            )
            model.machineName = "macmini"
            return model
        }
        const val PREFERENCES = "dsh-anywhere"
        const val KEY_SERVER_ADDRESS = "dsh-anywhere.server-address"
        const val KEY_GROUPING = "dsh-anywhere.session-list-grouping"
        const val KEY_LANGUAGE = "dsh-anywhere.language"
        const val KEY_COLLAPSED_GROUPS = "dsh-anywhere.collapsed-groups"
        const val KEY_USAGE_FOOTER = "dsh-anywhere.show-session-usage"
        const val KEY_COMPOSER_COLLAPSED = "dsh-anywhere.collapse-composer-controls"
        const val KEY_WORKSPACE_ALIASES = "dsh-anywhere.workspace-aliases"
        const val KEY_HIDDEN_WORKSPACES = "dsh-anywhere.hidden-workspaces"
        const val KEY_HIDDEN_MESSAGES = "dsh-anywhere.hidden-messages"
        const val KEY_LAST_READ_SESSIONS = "dsh-anywhere.last-read-session-timestamps"
        const val KEY_UNREAD_BASELINE = "dsh-anywhere.unread-baseline"

        // (Preference keys deliberately match iOS's UserDefaults names.)
    }
}
