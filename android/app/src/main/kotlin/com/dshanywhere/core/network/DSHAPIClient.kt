package com.dshanywhere.core.network

import com.dshanywhere.core.protocol.DSHJson
import com.dshanywhere.core.protocol.DSHPairingCredential
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.serializer
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.net.URL
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** A persisted relay identity; the bearer token lives in the token store. */
@Serializable
data class DSHRemoteProfile(
    val relayBaseURL: String,
    val deviceId: String,
    val machineId: String,
    val machineName: String,
) {
    val url: URL get() = URL(relayBaseURL)
}

/** One device paired to a machine, as the relay reports it. */
@Serializable
data class DSHRelayDevice(
    val deviceId: String,
    val name: String,
    val createdAt: Long,
) {
    val id: String get() = deviceId
}

sealed class DSHAPIError(message: String) : Exception(message) {
    class InvalidServerURL : DSHAPIError("Enter a valid Relay address.")
    class InsecureRelayURL :
        DSHAPIError("Relay addresses must use HTTPS (HTTP is allowed only for localhost testing).")
    class InvalidResponse : DSHAPIError("The Relay returned an invalid response.")
    class Http(val status: Int, msg: String) : DSHAPIError("Relay error $status: $msg")
    class MissingCredentials : DSHAPIError("Pair this iPhone with a Mac first.")
}

@Serializable
private data class PairResponse(
    val deviceId: String,
    val deviceToken: String,
    val machineName: String? = null,
)

@Serializable
private data class DeviceListResponse(val devices: List<DSHRelayDevice> = emptyList())

@Serializable
private data class ServerError(val error: String? = null, val message: String? = null)

/**
 * Relay REST client. Mirrors `DSHAPIClient` in
 * ios/DSHAnywhere/Core/Networking/DSHAPIClient.swift.
 */
class DSHAPIClient(
    private val relayBaseURL: URL,
    private val client: OkHttpClient = OkHttpClient(),
) {
    companion object {
        /**
         * A public relay must be HTTPS. The narrow HTTP exception keeps local
         * integration tests and a developer's localhost relay practical.
         */
        fun relayBaseURL(input: String): URL {
            val trimmed = input.trim()
            val url = runCatching { URL(trimmed) }.getOrNull()
                ?: throw DSHAPIError.InvalidServerURL()
            val scheme = url.protocol.lowercase()
            val host = url.host
            if (host.isEmpty()) throw DSHAPIError.InvalidServerURL()
            if (scheme == "http") {
                val localHosts = listOf("localhost", "127.0.0.1", "::1")
                if (host.lowercase() !in localHosts) throw DSHAPIError.InsecureRelayURL()
            } else if (scheme != "https") {
                throw DSHAPIError.InvalidServerURL()
            }
            val path = url.path.trim('/')
            val portPart = if (url.port != -1) ":${url.port}" else ""
            return runCatching {
                URL("$scheme://$host$portPart${if (path.isEmpty()) "" else "/$path"}")
            }.getOrElse { throw DSHAPIError.InvalidServerURL() }
        }

        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }

    suspend fun pair(
        machineId: String,
        credential: DSHPairingCredential,
        deviceName: String,
    ): Pair<DSHRemoteProfile, String> {
        val body = buildJsonObject {
            put("machineId", JsonPrimitive(machineId))
            put("deviceName", JsonPrimitive(deviceName))
            when (credential) {
                is DSHPairingCredential.Secret -> put("pairingSecret", JsonPrimitive(credential.value))
                is DSHPairingCredential.Code -> put("pairingCode", JsonPrimitive(credential.value))
            }
        }
        val request = makeRequest("POST", listOf("v1", "pair"), bearerToken = null)
            .post(body.toString().toRequestBody(JSON_MEDIA))
            .build()
        val response: PairResponse = send(request)
        val profile = DSHRemoteProfile(
            relayBaseURL = relayBaseURL.toString(),
            deviceId = response.deviceId,
            machineId = machineId,
            machineName = response.machineName ?: machineId,
        )
        return profile to response.deviceToken
    }

    /** Devices paired to one machine; carries identity and timestamps only. */
    suspend fun devices(machineId: String, token: String): List<DSHRelayDevice> {
        val request = makeRequest("GET", listOf("v1", "machines", machineId, "devices"), token).build()
        return send<DeviceListResponse>(request).devices
    }

    suspend fun revokeDevice(machineId: String, deviceId: String, token: String) {
        val request = makeRequest(
            "DELETE", listOf("v1", "machines", machineId, "devices", deviceId), token,
        ).build()
        execute(request)
    }

    private fun makeRequest(method: String, path: List<String>, bearerToken: String?): Request.Builder {
        var url = relayBaseURL.toString().trimEnd('/')
        for (component in path) url += "/" + component
        val builder = Request.Builder().url(url)
        // OkHttp rejects POST without a body; POST callers attach .post() after.
        if (method != "POST") builder.method(method, null)
        if (bearerToken != null) builder.header("Authorization", "Bearer $bearerToken")
        return builder
    }

    private suspend inline fun <reified V : Any> send(request: Request): V {
        val data = execute(request)
        val element = runCatching { DSHJson.parseToJsonElement(data) }
            .getOrElse { throw DSHAPIError.InvalidResponse() }
        return runCatching { DSHJson.decodeFromJsonElement(serializer<V>(), element) }
            .getOrElse { throw DSHAPIError.InvalidResponse() }
    }

    /** Runs the call asynchronously and validates the HTTP status. */
    private suspend fun execute(request: Request): String {
        val call = client.newCall(request)
        val response = suspendCancellableCoroutine { continuation ->
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: java.io.IOException) {
                    continuation.resumeWithException(DSHAPIError.InvalidResponse())
                }

                override fun onResponse(call: Call, response: Response) {
                    continuation.resume(response)
                }
            })
        }
        response.use { resp ->
            val data = resp.body?.string() ?: ""
            if (resp.code !in 200..299) {
                val serverError = runCatching {
                    DSHJson.decodeFromString(ServerError.serializer(), data)
                }.getOrNull()
                val message = serverError?.message ?: serverError?.error
                    ?: data.ifEmpty { "Request failed" }
                throw DSHAPIError.Http(resp.code, message)
            }
            return data
        }
    }
}
