package com.dshanywhere.core.store

import com.dshanywhere.core.protocol.DSHApprovalRequest
import com.dshanywhere.core.protocol.DSHApprovalResolution
import com.dshanywhere.core.protocol.DSHAssistantDelta
import com.dshanywhere.core.protocol.DSHChatMessage
import com.dshanywhere.core.protocol.DSHCommandResult
import com.dshanywhere.core.protocol.DSHEnvelope
import com.dshanywhere.core.protocol.DSHEvent
import com.dshanywhere.core.protocol.DSHEventKind
import com.dshanywhere.core.protocol.DSHMessageRole
import com.dshanywhere.core.protocol.DSHModelCatalog
import com.dshanywhere.core.protocol.DSHModelChangeNotice
import com.dshanywhere.core.protocol.DSHPermissionUpdate
import com.dshanywhere.core.protocol.DSHProtocolError
import com.dshanywhere.core.protocol.DSHQuestionRequest
import com.dshanywhere.core.protocol.DSHQuestionResolution
import com.dshanywhere.core.protocol.DSHReasoning
import com.dshanywhere.core.protocol.DSHSessionMetadataUpdate
import com.dshanywhere.core.protocol.DSHSessionSummary
import com.dshanywhere.core.protocol.DSHSessionUsage
import com.dshanywhere.core.protocol.DSHToolActivity
import com.dshanywhere.core.protocol.DSHTurnState
import com.dshanywhere.core.protocol.DSHUploadedAttachment
import com.dshanywhere.core.protocol.DSHUsageUpdate
import com.dshanywhere.core.protocol.startsNewSequenceEpoch
import com.dshanywhere.core.network.DSHConnectionState

/**
 * The store snapshot the UI renders. Mirrors `DSHStoreState`.
 */
data class DSHStoreState(
    val sessions: List<DSHSessionSummary> = emptyList(),
    /** Prevents an empty-state flash while the first snapshot is in flight. */
    val hasLoadedSessions: Boolean = false,
    val messagesBySession: Map<String, List<DSHChatMessage>> = emptyMap(),
    val toolsBySession: Map<String, List<DSHToolActivity>> = emptyMap(),
    val pendingApprovals: List<DSHApprovalRequest> = emptyList(),
    val pendingQuestions: List<DSHQuestionRequest> = emptyList(),
    val turnStateBySession: Map<String, String> = emptyMap(),
    val modelCatalog: DSHModelCatalog? = null,
    val usageBySession: Map<String, DSHSessionUsage> = emptyMap(),
    val permissionBySession: Map<String, DSHPermissionUpdate> = emptyMap(),
    val metadataBySession: Map<String, DSHSessionMetadataUpdate> = emptyMap(),
    val modelChangesBySession: Map<String, List<DSHModelChangeNotice>> = emptyMap(),
    val commandResultsBySession: Map<String, List<DSHCommandResult>> = emptyMap(),
    val attachmentsBySession: Map<String, List<DSHUploadedAttachment>> = emptyMap(),
    /** Errors keyed by the request id carried as the error envelope's message id. */
    val protocolErrorsByRequestID: Map<String, String> = emptyMap(),
    val unknownEvents: List<DSHEnvelope> = emptyList(),
    val lastSequence: Long = 0,
    /**
     * The socket to the public relay and the presence of the Mac Connector are
     * independent. Keeping both prevents a healthy relay from making an offline
     * Mac look reachable.
     */
    val transportState: DSHConnectionState = DSHConnectionState.Disconnected,
    val machineOnline: Boolean = false,
    /**
     * `null` means the Connector is present but the local Harness bridge has not
     * answered yet; existing protocol events prove whether it is usable.
     */
    val bridgeReachable: Boolean? = null,
    val connectionState: DSHConnectionState = DSHConnectionState.Disconnected,
)

/**
 * Pure, deterministic event reducer. Keeping this separate from the observable
 * store makes all event ordering and duplicate handling testable. Mirrors
 * `DSHEventReducer` in DSHEventStore.swift.
 */
object DSHEventReducer {

    fun reduce(event: DSHEvent, state: DSHStoreState): DSHStoreState {
        // Transport controls are local, out-of-band signals and therefore do
        // not participate in the Connector event sequence/replay window.
        when (val control = event.kind) {
            is DSHEventKind.TransportState -> {
                var controlled = state.copy(transportState = control.state)
                if (control.state != DSHConnectionState.Connected) {
                    controlled = controlled.copy(
                        machineOnline = false,
                        bridgeReachable = null,
                        connectionState = control.state,
                    )
                }
                return controlled
            }
            is DSHEventKind.MachinePresence -> {
                var controlled = state
                if (!control.online || !state.machineOnline) controlled = controlled.copy(bridgeReachable = null)
                controlled = controlled.copy(
                    machineOnline = control.online,
                    connectionState = if (control.online) DSHConnectionState.Connected else DSHConnectionState.Disconnected,
                )
                return controlled
            }
            else -> Unit
        }

        var next = state
        if (event.startsNewSequenceEpoch(comparedTo = next.lastSequence)) {
            // A bridge/Connector restart resets its in-memory replay buffer to
            // sequence 1. `session.snapshot` is a complete, authoritative
            // response to a refresh, so it can establish the new epoch even if
            // the preceding connection.ready was not replayed.
            next = next.copy(lastSequence = 0)
        }
        // Sequence numbers are monotonic at the transport boundary. Replaying an
        // old event must not duplicate a message or roll state backwards.
        if (event.sequence <= next.lastSequence) return next
        next = next.copy(lastSequence = event.sequence)

        when (val kind = event.kind) {
            is DSHEventKind.ConnectionReady ->
                next = next.copy(
                    transportState = DSHConnectionState.Connected,
                    machineOnline = true,
                    bridgeReachable = true,
                    connectionState = DSHConnectionState.Connected,
                )

            is DSHEventKind.SessionSnapshot -> {
                // Only touch the array when the content actually changed; the
                // Connector pushes snapshots often and reassigning anyway made
                // SwiftUI re-diff every row (visible flicker).
                if (kind.sessions != next.sessions) {
                    next = next.copy(sessions = kind.sessions)
                }
                // A snapshot is an answer from the bridge, so the Harness is
                // demonstrably usable.
                next = next.copy(hasLoadedSessions = true, bridgeReachable = true)
            }

            is DSHEventKind.SessionCreated -> {
                val index = next.sessions.indexOfFirst { it.id == kind.session.id }
                val sessions = if (index >= 0) {
                    next.sessions.toMutableList().also { it[index] = kind.session }
                } else {
                    next.sessions + kind.session
                }
                next = next.copy(sessions = sessions)
            }

            is DSHEventKind.UserMessageAccepted -> {
                val stamped = kind.message.copy(sequence = event.envelope.sequence)
                next = next.copy(
                    messagesBySession = appendOrReplace(
                        next.messagesBySession, event.envelope.sessionId, stamped,
                        key = { it.id },
                    ),
                )
            }

            is DSHEventKind.AssistantMessageCompleted -> {
                // A completion replaces the streaming partial, so carry the
                // reasoning that arrived as its own event back onto the message.
                val sessionId = event.envelope.sessionId
                val existing = sessionId?.let { sid ->
                    next.messagesBySession[sid]?.firstOrNull { it.id == kind.message.id }
                }
                val completed = if (existing != null) {
                    // Keep where the message started rather than where it
                    // finished, so interleaving with tool calls stays
                    // chronological.
                    kind.message.copy(reasoning = existing.reasoning, sequence = existing.sequence)
                } else {
                    kind.message.copy(sequence = event.envelope.sequence)
                }
                next = next.copy(
                    messagesBySession = appendOrReplace(
                        next.messagesBySession, event.envelope.sessionId, completed,
                        key = { it.id },
                    ),
                )
            }

            is DSHEventKind.AssistantReasoning -> {
                val sessionId = event.envelope.sessionId ?: ""
                val messages = next.messagesBySession.getOrDefault(sessionId, emptyList()).toMutableList()
                val index = messages.indexOfFirst { it.id == kind.reasoning.messageId }
                if (index >= 0) {
                    messages[index] = messages[index].copy(reasoning = kind.reasoning.text)
                } else {
                    messages.add(
                        DSHChatMessage(
                            id = kind.reasoning.messageId,
                            role = DSHMessageRole.assistant,
                            markdown = "",
                            reasoning = kind.reasoning.text,
                            sequence = event.envelope.sequence,
                        ),
                    )
                }
                next = next.copy(messagesBySession = next.messagesBySession + (sessionId to messages))
            }

            is DSHEventKind.AssistantMessageDelta -> {
                val sessionId = event.envelope.sessionId ?: ""
                val messages = next.messagesBySession.getOrDefault(sessionId, emptyList()).toMutableList()
                val index = messages.indexOfFirst { it.id == kind.delta.messageId }
                if (index >= 0) {
                    messages[index] = messages[index].copy(markdown = messages[index].markdown + kind.delta.text)
                } else {
                    messages.add(
                        DSHChatMessage(
                            id = kind.delta.messageId,
                            role = DSHMessageRole.assistant,
                            markdown = kind.delta.text,
                            sequence = event.envelope.sequence,
                        ),
                    )
                }
                next = next.copy(messagesBySession = next.messagesBySession + (sessionId to messages))
            }

            is DSHEventKind.ToolStarted -> {
                val stamped = kind.tool.copy(sequence = event.envelope.sequence)
                next = next.copy(
                    toolsBySession = appendOrReplace(
                        next.toolsBySession, event.envelope.sessionId, stamped,
                        key = { it.id },
                    ),
                )
            }

            is DSHEventKind.ToolCompleted -> {
                // Keep the arrival order of the call itself: a completion
                // carries a later sequence but must not jump ahead of calls
                // made after it.
                val existing = event.envelope.sessionId?.let { sid ->
                    next.toolsBySession[sid]?.firstOrNull { it.id == kind.tool.id }
                }
                val stamped = kind.tool.copy(sequence = existing?.sequence ?: event.envelope.sequence)
                next = next.copy(
                    toolsBySession = appendOrReplace(
                        next.toolsBySession, event.envelope.sessionId, stamped,
                        key = { it.id },
                    ),
                )
            }

            is DSHEventKind.ApprovalRequested -> {
                if (next.pendingApprovals.none { it.id == kind.approval.id }) {
                    next = next.copy(pendingApprovals = next.pendingApprovals + kind.approval)
                }
            }

            is DSHEventKind.ApprovalResolved ->
                next = next.copy(pendingApprovals = next.pendingApprovals.filterNot { it.id == kind.resolution.id })

            is DSHEventKind.QuestionAsked -> {
                if (next.pendingQuestions.none { it.id == kind.request.id }) {
                    next = next.copy(pendingQuestions = next.pendingQuestions + kind.request)
                }
            }

            is DSHEventKind.QuestionResolved ->
                next = next.copy(pendingQuestions = next.pendingQuestions.filterNot { it.id == kind.resolution.id })

            is DSHEventKind.TurnStateChanged ->
                next = next.copy(turnStateBySession = next.turnStateBySession + (kind.turn.sessionId to kind.turn.state))

            is DSHEventKind.ModelCatalog ->
                next = next.copy(modelCatalog = kind.catalog)

            is DSHEventKind.UsageUpdated -> {
                val index = next.sessions.indexOfFirst { it.id == kind.update.sessionId }
                val sessions = if (index >= 0) {
                    next.sessions.toMutableList().also { it[index] = it[index].copy(usage = kind.update.usage) }
                } else next.sessions
                next = next.copy(
                    usageBySession = next.usageBySession + (kind.update.sessionId to kind.update.usage),
                    sessions = sessions,
                )
            }

            is DSHEventKind.PermissionUpdated -> {
                val index = next.sessions.indexOfFirst { it.id == kind.update.sessionId }
                val sessions = if (index >= 0) {
                    next.sessions.toMutableList().also { it[index] = it[index].copy(permissionMode = kind.update.mode) }
                } else next.sessions
                next = next.copy(
                    permissionBySession = next.permissionBySession + (kind.update.sessionId to kind.update),
                    sessions = sessions,
                )
            }

            is DSHEventKind.SessionMetadataUpdated -> {
                val index = next.sessions.indexOfFirst { it.id == kind.update.sessionId }
                val sessions = if (index >= 0) {
                    val s = next.sessions[index]
                    val updated = s.copy(
                        provider = kind.update.provider ?: s.provider,
                        model = kind.update.model ?: s.model,
                        reasoningEffort = kind.update.reasoningEffort ?: s.reasoningEffort,
                    )
                    next.sessions.toMutableList().also { it[index] = updated }
                } else next.sessions
                next = next.copy(
                    metadataBySession = next.metadataBySession + (kind.update.sessionId to kind.update),
                    sessions = sessions,
                )
            }

            is DSHEventKind.ModelChanged -> {
                val stamped = kind.notice.copy(
                    sequence = event.envelope.sequence,
                    timestamp = event.envelope.timestamp,
                )
                val values = next.modelChangesBySession
                    .getOrDefault(stamped.sessionId, emptyList()).toMutableList()
                val index = values.indexOfFirst { it.id == stamped.id }
                if (index >= 0) values[index] = stamped else values.add(stamped)
                next = next.copy(
                    modelChangesBySession = next.modelChangesBySession + (stamped.sessionId to values),
                )
            }

            is DSHEventKind.CommandResult -> {
                // The command.result payload intentionally stays small and does
                // not carry transport metadata. Stamp the enclosing event's
                // sequence here so the transcript can place the acknowledgement
                // where it happened instead of appending it after every message.
                val stamped = kind.result.copy(sequence = event.envelope.sequence)
                val values = next.commandResultsBySession
                    .getOrDefault(stamped.sessionId, emptyList()).toMutableList()
                val index = values.indexOfFirst { it.id == stamped.id }
                if (index >= 0) values[index] = stamped else values.add(stamped)
                next = next.copy(
                    commandResultsBySession = next.commandResultsBySession + (stamped.sessionId to values),
                )
            }

            is DSHEventKind.AttachmentUploaded -> {
                val values = next.attachmentsBySession
                    .getOrDefault(kind.attachment.sessionId, emptyList())
                if (values.none { it.id == kind.attachment.id }) {
                    next = next.copy(
                        attachmentsBySession = next.attachmentsBySession +
                            (kind.attachment.sessionId to values + kind.attachment),
                    )
                }
            }

            is DSHEventKind.ProtocolError -> {
                next = next.copy(
                    protocolErrorsByRequestID = next.protocolErrorsByRequestID +
                        (event.envelope.messageId to kind.error.message),
                )
                if (kind.error.code == "bridge-request-failed") {
                    next = next.copy(bridgeReachable = false)
                }
            }

            DSHEventKind.Unknown ->
                next = next.copy(unknownEvents = next.unknownEvents + event.envelope)

            else -> Unit
        }
        return next
    }

    fun reduceAll(events: Iterable<DSHEvent>, state: DSHStoreState): DSHStoreState {
        var current = state
        for (event in events) current = reduce(event, current)
        return current
    }

    private fun <T> appendOrReplace(
        store: Map<String, List<T>>,
        sessionId: String?,
        value: T,
        key: (T) -> String,
    ): Map<String, List<T>> {
        val mapKey = sessionId ?: ""
        val values = store.getOrDefault(mapKey, emptyList()).toMutableList()
        val index = values.indexOfFirst { key(it) == key(value) }
        if (index >= 0) values[index] = value else values.add(value)
        return store + (mapKey to values)
    }
}
