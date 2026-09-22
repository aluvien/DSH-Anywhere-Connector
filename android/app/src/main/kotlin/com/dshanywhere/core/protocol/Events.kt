package com.dshanywhere.core.protocol

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import com.dshanywhere.core.store.DSHDirectoryListing
import com.dshanywhere.core.store.DSHModeCatalog
import com.dshanywhere.core.store.DSHWorkspaceOption

@kotlinx.serialization.Serializable
private data class DSHWorkspaceCatalogPayload(val workspaces: List<DSHWorkspaceOption> = emptyList())

/**
 * Relay transport messages. The relay deliberately wraps the existing Harness
 * protocol; keeping the wrapper separate means a relay acknowledgement can never
 * be mistaken for a Harness event by the store. Mirrors the `DSHRelay*` types
 * in DSHProtocol.swift.
 */
@kotlinx.serialization.Serializable
enum class DSHRelayRole { machine, device }

@kotlinx.serialization.Serializable
data class DSHRelayReadyMessage(
    val type: String,
    val machineId: String,
    val role: DSHRelayRole,
    val connectionId: String,
    val serverTime: Long,
)

@kotlinx.serialization.Serializable
data class DSHRelayPresenceMessage(
    val type: String,
    val machineId: String,
    val role: DSHRelayRole,
    val online: Boolean,
    val deviceId: String? = null,
    val serverTime: Long,
)

@kotlinx.serialization.Serializable
data class DSHRelayErrorMessage(
    val type: String,
    val code: String,
    val message: String,
    val machineId: String? = null,
    val messageId: String? = null,
)

@kotlinx.serialization.Serializable
data class DSHRelayPayloadMessage(
    // No declaration-site default: with `encodeDefaults = false` a defaulted
    // property whose value equals the default is *omitted* from the JSON, and
    // the relay rejects a payload message without `type`. Swift always encodes
    // this non-optional property, so the factories pass it explicitly.
    val type: String,
    val machineId: String,
    val messageId: String,
    val sender: DSHRelayRole,
    val targetDeviceId: String? = null,
    val body: JsonElement,
) {
    companion object {
        fun wrapping(machineId: String, sender: DSHRelayRole, body: JsonElement,
                     messageId: String = java.util.UUID.randomUUID().toString()) =
            DSHRelayPayloadMessage(
                type = "relay.payload",
                machineId = machineId, messageId = messageId, sender = sender, body = body,
            )

        fun wrappingCommand(machineId: String, sender: DSHRelayRole, command: DSHCommand,
                            messageId: String = java.util.UUID.randomUUID().toString()): DSHRelayPayloadMessage =
            DSHRelayPayloadMessage(
                type = "relay.payload",
                machineId = machineId,
                messageId = messageId,
                sender = sender,
                body = DSHJson.encodeToJsonElement(DSHCommand.serializer(), command),
            )
    }

    fun encodeText(): String = DSHJson.encodeToString(DSHRelayPayloadMessage.serializer(), this)
}

sealed class DSHRelayMessage {
    data class Ready(val message: DSHRelayReadyMessage) : DSHRelayMessage()
    data class Presence(val message: DSHRelayPresenceMessage) : DSHRelayMessage()
    data class Payload(val message: DSHRelayPayloadMessage) : DSHRelayMessage()
    data class Error(val message: DSHRelayErrorMessage) : DSHRelayMessage()

    companion object {
        /** Returns null for unknown/undecodable messages, mirroring the Swift throw. */
        fun parse(json: String): DSHRelayMessage? {
            val element = runCatching { DSHJson.parseToJsonElement(json) }.getOrNull() ?: return null
            val type = runCatching { element.jsonObject["type"]?.jsonPrimitive?.content }.getOrNull()
                ?: return null
            return when (type) {
                "relay.ready" -> runCatching {
                    Ready(DSHJson.decodeFromJsonElement(DSHRelayReadyMessage.serializer(), element))
                }.getOrNull()
                "relay.presence" -> runCatching {
                    Presence(DSHJson.decodeFromJsonElement(DSHRelayPresenceMessage.serializer(), element))
                }.getOrNull()
                "relay.payload" -> runCatching {
                    Payload(DSHJson.decodeFromJsonElement(DSHRelayPayloadMessage.serializer(), element))
                }.getOrNull()
                "relay.error" -> runCatching {
                    Error(DSHJson.decodeFromJsonElement(DSHRelayErrorMessage.serializer(), element))
                }.getOrNull()
                else -> null
            }
        }
    }
}

/** What arrived on the wire, decoded to a typed kind when recognised. */
sealed interface DSHEventKind {
    /**
     * Phone-to-Relay socket state. Deliberately separate from Mac presence: the
     * relay can remain reachable after the Connector goes away.
     */
    data class TransportState(val state: com.dshanywhere.core.network.DSHConnectionState) : DSHEventKind
    /** Live relay presence for the paired Mac Connector. */
    data class MachinePresence(val online: Boolean) : DSHEventKind
    data object ConnectionReady : DSHEventKind
    data class SessionSnapshot(val sessions: List<DSHSessionSummary>) : DSHEventKind
    data class SessionCreated(val session: DSHSessionSummary) : DSHEventKind
    data class UserMessageAccepted(val message: DSHChatMessage) : DSHEventKind
    data class AssistantMessageDelta(val delta: DSHAssistantDelta) : DSHEventKind
    data class AssistantMessageCompleted(val message: DSHChatMessage) : DSHEventKind
    data class AssistantMessageDiscarded(val discarded: DSHDiscardedMessage) : DSHEventKind
    data class ToolStarted(val tool: DSHToolActivity) : DSHEventKind
    data class ToolCompleted(val tool: DSHToolActivity) : DSHEventKind
    data class ApprovalRequested(val approval: DSHApprovalRequest) : DSHEventKind
    data class ApprovalResolved(val resolution: DSHApprovalResolution) : DSHEventKind
    data class TurnStateChanged(val turn: DSHTurnState) : DSHEventKind
    data class ModelCatalog(val catalog: DSHModelCatalog) : DSHEventKind
    data class WorkspaceCatalog(val workspaces: List<DSHWorkspaceOption>) : DSHEventKind
    data class WorkspaceCreated(val workspace: DSHWorkspaceOption) : DSHEventKind
    data class ModeCatalog(val catalog: DSHModeCatalog) : DSHEventKind
    data class DirectoryListing(val listing: DSHDirectoryListing) : DSHEventKind
    data class UsageUpdated(val update: DSHUsageUpdate) : DSHEventKind
    data class PermissionUpdated(val update: DSHPermissionUpdate) : DSHEventKind
    data class SessionMetadataUpdated(val update: DSHSessionMetadataUpdate) : DSHEventKind
    data class ModelChanged(val notice: DSHModelChangeNotice) : DSHEventKind
    data class CommandResult(val result: DSHCommandResult) : DSHEventKind
    data class AttachmentUploaded(val attachment: DSHUploadedAttachment) : DSHEventKind
    data class PromptAccepted(val accepted: DSHPromptAccepted) : DSHEventKind
    data class AssistantReasoning(val reasoning: DSHReasoning) : DSHEventKind
    data class QuestionAsked(val request: DSHQuestionRequest) : DSHEventKind
    data class QuestionResolved(val resolution: DSHQuestionResolution) : DSHEventKind
    data class ProtocolError(val error: DSHProtocolError) : DSHEventKind
    data class HistoryStarted(val batch: DSHHistoryBatch) : DSHEventKind
    data class HistoryCompleted(val batch: DSHHistoryBatch) : DSHEventKind
    data object Unknown : DSHEventKind

    /**
     * Payloads for event types this client does not know yet are retained on
     * the envelope rather than discarded, keeping the wire protocol forward
     * compatible.
     */
    companion object {
        fun decode(type: String, payload: JsonElement): DSHEventKind {
            fun <T : Any> decodeAs(serializer: kotlinx.serialization.KSerializer<T>): T? =
                runCatching { DSHJson.decodeFromJsonElement(serializer, payload) }.getOrNull()
            return when (type) {
                "transport.state" ->
                    com.dshanywhere.core.network.connectionStateFromWire(payload)?.let { TransportState(it) } ?: Unknown
                "machine.presence" -> decodeAs(Boolean.serializer())?.let { MachinePresence(it) } ?: Unknown
                "connection.ready" -> ConnectionReady
                "session.snapshot" ->
                    decodeAs(kotlinx.serialization.builtins.ListSerializer(DSHSessionSummary.serializer()))
                        ?.let { SessionSnapshot(it) } ?: Unknown
                "session.created" -> decodeAs(DSHSessionSummary.serializer())?.let { SessionCreated(it) } ?: Unknown
                "user.message.accepted" -> decodeAs(DSHChatMessage.serializer())?.let { UserMessageAccepted(it) } ?: Unknown
                "assistant.message.delta" -> decodeAs(DSHAssistantDelta.serializer())?.let { AssistantMessageDelta(it) } ?: Unknown
                "assistant.message.completed" -> decodeAs(DSHChatMessage.serializer())?.let { AssistantMessageCompleted(it) } ?: Unknown
                "assistant.message.discarded" -> decodeAs(DSHDiscardedMessage.serializer())?.let { AssistantMessageDiscarded(it) } ?: Unknown
                "tool.started" -> decodeAs(DSHToolActivity.serializer())?.let { ToolStarted(it) } ?: Unknown
                "tool.completed" -> decodeAs(DSHToolActivity.serializer())?.let { ToolCompleted(it) } ?: Unknown
                "approval.requested" -> decodeAs(DSHApprovalRequest.serializer())?.let { ApprovalRequested(it) } ?: Unknown
                "approval.resolved" -> decodeAs(DSHApprovalResolution.serializer())?.let { ApprovalResolved(it) } ?: Unknown
                "turn.state.changed" -> decodeAs(DSHTurnState.serializer())?.let { TurnStateChanged(it) } ?: Unknown
                "model.catalog" -> decodeAs(DSHModelCatalog.serializer())?.let { ModelCatalog(it) } ?: Unknown
                "workspace.catalog" -> decodeAs(DSHWorkspaceCatalogPayload.serializer())?.let { payload ->
                    WorkspaceCatalog(payload.workspaces.map { it.copy(name = it.resolvedName) })
                } ?: Unknown
                "workspace.created" -> decodeAs(DSHWorkspaceOption.serializer())?.let {
                    WorkspaceCreated(it.copy(name = it.resolvedName))
                } ?: Unknown
                "mode.catalog" -> decodeAs(DSHModeCatalog.serializer())?.let { ModeCatalog(it) } ?: Unknown
                "directory.list" -> decodeAs(DSHDirectoryListing.serializer())?.let { DirectoryListing(it) } ?: Unknown
                "usage.updated" -> decodeAs(DSHUsageUpdate.serializer())?.let { UsageUpdated(it) } ?: Unknown
                "permission.updated" -> decodeAs(DSHPermissionUpdate.serializer())?.let { PermissionUpdated(it) } ?: Unknown
                "session.metadata.updated" -> decodeAs(DSHSessionMetadataUpdate.serializer())?.let { SessionMetadataUpdated(it) } ?: Unknown
                "session.model.changed" -> decodeAs(DSHModelChangeNotice.serializer())?.let { ModelChanged(it) } ?: Unknown
                "command.result" -> decodeAs(DSHCommandResult.serializer())?.let { CommandResult(it) } ?: Unknown
                "attachment.uploaded" -> decodeAs(DSHUploadedAttachment.serializer())?.let { AttachmentUploaded(it) } ?: Unknown
                "prompt.accepted" -> decodeAs(DSHPromptAccepted.serializer())?.let { PromptAccepted(it) } ?: Unknown
                "assistant.reasoning" -> decodeAs(DSHReasoning.serializer())?.let { AssistantReasoning(it) } ?: Unknown
                "question.asked" -> decodeAs(DSHQuestionRequest.serializer())?.let { QuestionAsked(it) } ?: Unknown
                "question.resolved" -> decodeAs(DSHQuestionResolution.serializer())?.let { QuestionResolved(it) } ?: Unknown
                "protocol.error" -> decodeAs(DSHProtocolError.serializer())?.let { ProtocolError(it) } ?: Unknown
                "history.started" -> decodeAs(DSHHistoryBatch.serializer())?.let { HistoryStarted(it) } ?: Unknown
                "history.completed" -> decodeAs(DSHHistoryBatch.serializer())?.let { HistoryCompleted(it) } ?: Unknown
                else -> Unknown
            }
        }
    }
}

/** One decoded Harness event: the envelope plus its recognised payload. */
class DSHEvent(val envelope: DSHEnvelope) {
    val kind: DSHEventKind = DSHEventKind.decode(envelope.type, envelope.payload)

    val id: String get() = envelope.messageId
    val sequence: Long get() = envelope.sequence
    val type: String get() = envelope.type

    companion object {
        /** Decode a relay payload body into an event, or null if malformed. */
        fun fromPayload(body: JsonElement): DSHEvent? =
            runCatching {
                DSHEvent(DSHJson.decodeFromJsonElement(DSHEnvelope.serializer(), body))
            }.getOrNull()
    }
}

/** Mirrors the `startsNewSequenceEpoch` extension in DSHEventStore.swift. */
fun DSHEvent.startsNewSequenceEpoch(comparedTo: Long): Boolean {
    if (sequence > comparedTo) return false
    return when (kind) {
        is DSHEventKind.ConnectionReady, is DSHEventKind.SessionSnapshot -> true
        else -> false
    }
}

private val unused: Unit = run {
    // Silence "unused import" churn for helpers referenced by callers of this file.
    val a: Any? = listOf<Any?>(null, JsonObject(emptyMap()), JsonArray(emptyList()))
}
