package com.dshanywhere.core.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID

/**
 * Shared Json configuration. `encodeDefaults = false` + `explicitNulls = false`
 * mirror the Swift encoders: optional fields that are absent are *omitted*, not
 * sent as JSON nulls, because the relay's strict schemas reject nulls.
 */
val DSHJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = false
    explicitNulls = false
}

fun epochMillisNow(): Long = System.currentTimeMillis()

/**
 * Envelope wrapping every Harness event crossing the relay. Mirrors
 * `DSHEnvelope` in ios/DSHAnywhere/Core/Protocol/DSHProtocol.swift.
 */
@Serializable
data class DSHEnvelope(
    val version: Int,
    val messageId: String,
    val deviceId: String,
    val machineId: String,
    val sessionId: String? = null,
    val sequence: Long,
    val timestamp: Long,
    val type: String,
    val payload: JsonElement,
    /** Non-null only for events emitted by a durable history replay. */
    val historyBatchId: String? = null,
)

/**
 * Commands sent from the device to the machine. Mirrors `DSHCommand`.
 *
 * `version`/`timestamp` intentionally carry no Kotlin *declaration-site*
 * defaults on the primary constructor so they are always encoded; factory
 * helpers supply the common values instead.
 */
@Serializable
data class DSHCommand(
    val version: Int,
    val requestId: String,
    val deviceId: String,
    val machineId: String,
    val sessionId: String? = null,
    val timestamp: Long,
    val type: String,
    val payload: JsonElement,
) {
    companion object {
        fun new(
            deviceId: String,
            machineId: String,
            type: String,
            payload: JsonElement = buildJsonObject { },
            sessionId: String? = null,
            requestId: String = UUID.randomUUID().toString(),
        ) = DSHCommand(
            version = 1,
            requestId = requestId,
            deviceId = deviceId,
            machineId = machineId,
            sessionId = sessionId,
            timestamp = epochMillisNow(),
            type = type,
            payload = payload,
        )

        fun resume(deviceId: String, machineId: String, lastSequence: Long) =
            new(deviceId, machineId, "connection.resume",
                buildJsonObject { put("lastSequence", JsonPrimitive(lastSequence)) })

        fun sendPrompt(deviceId: String, machineId: String, sessionId: String, text: String) =
            sendPrompt(deviceId, machineId, sessionId, text, emptyList())

        fun sendPrompt(
            deviceId: String,
            machineId: String,
            sessionId: String,
            text: String,
            attachments: List<JsonElement> = emptyList(),
            mode: String = "queue",
            requestId: String = UUID.randomUUID().toString(),
        ): DSHCommand {
            val payload = buildJsonObject {
                put("text", JsonPrimitive(text))
                put("mode", JsonPrimitive(mode))
                if (attachments.isNotEmpty()) {
                    // The Harness treats `content` as the canonical multipart prompt.
                    // Keep the text in that same array; sending it only beside a file
                    // reference makes the bridge accept the upload while silently
                    // dropping the text part.
                    val content = kotlinx.serialization.json.JsonArray(
                        buildList {
                            if (text.isNotBlank()) {
                                add(buildJsonObject {
                                    put("type", JsonPrimitive("text"))
                                    put("text", JsonPrimitive(text))
                                })
                            }
                            addAll(attachments)
                        },
                    )
                    put("content", content)
                }
            }
            return new(deviceId, machineId, "prompt.send", payload, sessionId, requestId)
        }

        fun listSessions(deviceId: String, machineId: String, includeArchived: Boolean = false) =
            new(deviceId, machineId, "session.list",
                buildJsonObject { put("includeArchived", JsonPrimitive(includeArchived)) })

        fun openSession(
            deviceId: String,
            machineId: String,
            sessionId: String,
            streaming: Boolean = true,
        ) = new(deviceId, machineId, "session.open", buildJsonObject {
            put("sessionId", JsonPrimitive(sessionId))
            if (streaming) put("streaming", JsonPrimitive(true))
        }, sessionId)

        fun archiveSession(deviceId: String, machineId: String, sessionId: String, archived: Boolean) =
            new(deviceId, machineId, "session.archive",
                buildJsonObject { put("archived", JsonPrimitive(archived)) }, sessionId)

        fun renameSession(deviceId: String, machineId: String, sessionId: String, title: String) =
            new(deviceId, machineId, "session.rename",
                buildJsonObject { put("title", JsonPrimitive(title)) }, sessionId)

        fun directoryList(deviceId: String, machineId: String, path: String? = null) =
            new(deviceId, machineId, "directory.list", buildJsonObject {
                if (!path.isNullOrBlank()) put("path", JsonPrimitive(path))
            })

        fun workspaceCatalog(deviceId: String, machineId: String) =
            new(deviceId, machineId, "workspace.catalog")

        fun createWorkspace(deviceId: String, machineId: String, path: String, title: String? = null) =
            new(deviceId, machineId, "workspace.create", buildJsonObject {
                put("path", JsonPrimitive(path))
                if (!title.isNullOrBlank()) put("title", JsonPrimitive(title))
            })

        fun modeCatalog(deviceId: String, machineId: String) =
            new(deviceId, machineId, "mode.catalog")

        fun selectModel(deviceId: String, machineId: String, sessionId: String,
                        provider: String, model: String, reasoningEffort: String? = null) =
            new(deviceId, machineId, "session.model", buildJsonObject {
                put("provider", JsonPrimitive(provider))
                put("model", JsonPrimitive(model))
                if (reasoningEffort != null) put("reasoningEffort", JsonPrimitive(reasoningEffort))
            }, sessionId)

        fun renameWorkspace(deviceId: String, machineId: String, workspaceId: String, title: String) =
            new(deviceId, machineId, "workspace.rename", buildJsonObject {
                put("workspaceId", JsonPrimitive(workspaceId))
                put("title", JsonPrimitive(title))
            })

        fun deleteWorkspace(deviceId: String, machineId: String, workspaceId: String) =
            new(deviceId, machineId, "workspace.delete",
                buildJsonObject { put("workspaceId", JsonPrimitive(workspaceId)) })

        fun modelCatalog(deviceId: String, machineId: String) =
            new(deviceId, machineId, "model.catalog", buildJsonObject { })

        fun executeCommand(deviceId: String, machineId: String, sessionId: String,
                           line: String, attachments: List<JsonElement> = emptyList()) =
            new(deviceId, machineId, "command.execute", buildJsonObject {
                put("line", JsonPrimitive(line))
                if (attachments.isNotEmpty()) put("attachments", JsonArray(attachments))
            }, sessionId)

        fun setPermission(deviceId: String, machineId: String, sessionId: String, mode: String) =
            new(deviceId, machineId, "permission.set",
                buildJsonObject { put("mode", JsonPrimitive(mode)) }, sessionId)

        fun uploadAttachment(deviceId: String, machineId: String, sessionId: String,
                             name: String, data: ByteArray,
                             requestId: String = UUID.randomUUID().toString()) =
            new(deviceId, machineId, "attachment.upload", buildJsonObject {
                put("name", JsonPrimitive(name))
                put("data", JsonPrimitive(java.util.Base64.getEncoder().encodeToString(data)))
            }, sessionId, requestId)

        fun cancelTurn(deviceId: String, machineId: String, sessionId: String) =
            new(deviceId, machineId, "turn.cancel", buildJsonObject { }, sessionId)

        fun decideApproval(deviceId: String, machineId: String, sessionId: String,
                           approvalId: String, allow: Boolean) =
            new(deviceId, machineId, "approval.decide", buildJsonObject {
                put("approvalId", JsonPrimitive(approvalId))
                put("allow", JsonPrimitive(allow))
            }, sessionId)

        /**
         * One answered question. `selected` carries option labels verbatim, which
         * is what the Harness echoes back into the model's tool result.
         */
        fun answerQuestion(deviceId: String, machineId: String, sessionId: String,
                           questionId: String, answers: List<DSHQuestionAnswer>) =
            new(deviceId, machineId, "question.answer", buildJsonObject {
                put("questionId", JsonPrimitive(questionId))
                put("answers", JsonArray(answers.map { it.jsonObject() }))
            }, sessionId)
    }
}

/** One question's answer as sent back to the bridge. */
data class DSHQuestionAnswer(
    val id: String,
    val selected: List<String>,
    val custom: String? = null,
) {
    fun jsonObject(): JsonObject = buildJsonObject {
        put("id", JsonPrimitive(id))
        put("selected", JsonArray(selected.map { JsonPrimitive(it) }))
        if (custom != null) put("custom", JsonPrimitive(custom))
    }
}
