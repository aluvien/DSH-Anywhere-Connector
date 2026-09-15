package com.dshanywhere.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class DSHSessionUsage(
    val rounds: Int? = null,
    val steps: Int? = null,
    val inputTokens: Double? = null,
    val outputTokens: Double? = null,
    val totalTokens: Double? = null,
    val cacheReadTokens: Double? = null,
    val cacheWriteTokens: Double? = null,
    val cacheHitPercent: Double? = null,
    val tokensPerSecond: Double? = null,
    val contextUsed: Double? = null,
    val contextWindow: Double? = null,
)

@Serializable
data class DSHSessionSummary(
    val id: String,
    val title: String = "",
    val updatedAt: Long = 0,
    val cwd: String? = null,
    val workspaceId: String? = null,
    val workspaceName: String? = null,
    val archived: Boolean? = null,
    val running: Boolean? = null,
    val blank: Boolean? = null,
    val parentSessionId: String? = null,
    val agentPreset: String? = null,
    val mode: String? = null,
    val branch: String? = null,
    val provider: String? = null,
    val model: String? = null,
    val reasoningEffort: String? = null,
    val permissionMode: String? = null,
    val usage: DSHSessionUsage? = null,
)

@Serializable
data class DSHModelSelection(
    val provider: String,
    val model: String,
    val reasoningEffort: String? = null,
)

@Serializable
data class DSHModelReasoningEffort(
    val id: String,
    val name: String,
    val description: String? = null,
)

@Serializable
data class DSHModelReasoning(
    val efforts: List<DSHModelReasoningEffort> = emptyList(),
    val defaultEffort: String? = null,
)

@Serializable
data class DSHModelCatalogModel(
    val id: String,
    val name: String,
    val description: String? = null,
    val reasoning: DSHModelReasoning? = null,
)

@Serializable
data class DSHModelCatalogGroup(
    val id: String,
    val name: String,
    val models: List<DSHModelCatalogModel> = emptyList(),
)

@Serializable
data class DSHModelCatalogFailure(
    val id: String,
    val name: String,
    val message: String,
)

@Serializable
data class DSHModelCatalog(
    @SerialName("default") val default: DSHModelSelection,
    val routableProviders: List<String> = emptyList(),
    val groups: List<DSHModelCatalogGroup> = emptyList(),
    val failures: List<DSHModelCatalogFailure> = emptyList(),
)

@Serializable
enum class DSHMessageRole { user, assistant, system, tool }

/**
 * Metadata for a file/image that belongs to a chat message. The bytes are kept
 * in the app's local thumbnail cache; the wire event only carries the
 * receipt/name so a reconnect does not duplicate a large base64 payload.
 */
@Serializable
data class DSHMessageAttachment(
    val id: String,
    val name: String,
    val mediaType: String? = null,
    val receiptId: String? = null,
) {
    val isImage: Boolean
        get() {
            if (mediaType?.lowercase()?.startsWith("image/") == true) return true
            val ext = name.substringAfterLast('.', "").lowercase()
            return ext in listOf("png", "jpg", "jpeg", "heic", "webp", "gif")
        }
}

@Serializable
data class DSHChatMessage(
    val id: String,
    val role: DSHMessageRole,
    val markdown: String,
    val attachments: List<DSHMessageAttachment> = emptyList(),
    val usage: DSHSessionUsage? = null,
    val provider: String? = null,
    val model: String? = null,
    val reasoningEffort: String? = null,
    val contextWindow: Double? = null,
    /** Chain-of-thought for this message; the transcript folds it behind a disclosure. */
    val reasoning: String? = null,
    /** Sequence of the event that produced this message. Client-side only. */
    val sequence: Long? = null,
)

@Serializable
data class DSHAssistantDelta(
    val messageId: String,
    val text: String,
)

@Serializable
data class DSHReasoning(
    val messageId: String,
    val text: String,
)

@Serializable
data class DSHToolActivity(
    val id: String,
    val name: String,
    val status: String = "running",
    val detail: String? = null,
    /** Sequence of the event that produced this call. Client-side only. */
    val sequence: Long? = null,
)

@Serializable
data class DSHApprovalRequest(
    val id: String,
    val sessionId: String,
    val toolName: String,
    val reason: String,
    val expiresAt: Long? = null,
)

@Serializable
data class DSHApprovalResolution(
    val id: String,
    val allowed: Boolean,
)

@Serializable
data class DSHTurnState(
    val sessionId: String,
    val state: String,
)

@Serializable
data class DSHPermissionUpdate(
    val sessionId: String,
    val mode: String,
    val approvalPolicy: String? = null,
)

@Serializable
data class DSHUsageUpdate(
    val sessionId: String,
    val usage: DSHSessionUsage,
)

@Serializable
data class DSHSessionMetadataUpdate(
    val sessionId: String,
    val provider: String? = null,
    val model: String? = null,
    val reasoningEffort: String? = null,
    val contextWindow: Double? = null,
)

/**
 * Compact inline transcript marker emitted when a session changes model.
 * `sequence` is assigned from the enclosing envelope by the reducer and never
 * travels on the wire as part of the payload.
 */
@Serializable
data class DSHModelChangeNotice(
    val sessionId: String,
    val previous: DSHModelSelection? = null,
    val current: DSHModelSelection,
    val sequence: Long = 0,
    val timestamp: Long = epochMillisNow(),
) {
    val id: String get() = "$sessionId-$sequence-${current.provider}-${current.model}"
}

@Serializable
data class DSHCommandResult(
    val sessionId: String,
    val requestId: String,
    val matched: Boolean,
    val commandId: String? = null,
    val kind: String? = null,
    val text: String? = null,
    /** Assigned by the event reducer from the enclosing event. */
    val sequence: Long? = null,
) {
    val id: String get() = requestId
}

@Serializable
data class DSHUploadedAttachment(
    val sessionId: String,
    val requestId: String,
    val receiptId: String,
    val name: String,
    val mediaType: String? = null,
    val size: Int? = null,
) {
    val id: String get() = receiptId
}

/** One selectable answer for a question raised by `ask_user_question`. */
@Serializable
data class DSHQuestionOption(
    val label: String,
    val description: String? = null,
) {
    val id: String get() = label
}

@Serializable
data class DSHQuestion(
    val id: String,
    val question: String,
    val header: String? = null,
    /** Supporting detail, such as a plan submitted for review. */
    val detail: String? = null,
    val options: List<DSHQuestionOption>? = null,
    val multiSelect: Boolean? = null,
)

@Serializable
data class DSHQuestionRequest(
    val id: String,
    val sessionId: String,
    val questions: List<DSHQuestion> = emptyList(),
    val expiresAt: Long? = null,
)

@Serializable
data class DSHQuestionResolution(
    val id: String,
    val sessionId: String,
)

/**
 * An error correlated to the command that caused it. Connector errors use the
 * command request id as the envelope message id, so the composer can stop
 * waiting immediately instead of reporting a generic attachment timeout.
 */
@Serializable
data class DSHProtocolError(
    val code: String,
    val message: String,
    val retryable: Boolean = false,
)
