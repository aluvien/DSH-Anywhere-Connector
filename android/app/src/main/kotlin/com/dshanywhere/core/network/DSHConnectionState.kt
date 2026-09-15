package com.dshanywhere.core.network

/**
 * Connection lifecycle for the relay socket. Mirrors `DSHConnectionState`.
 */
sealed class DSHConnectionState {
    data object Disconnected : DSHConnectionState()
    data object Connecting : DSHConnectionState()
    data object Connected : DSHConnectionState()
    data class Reconnecting(val attempt: Int) : DSHConnectionState()
    data class Failed(val message: String) : DSHConnectionState()

    override fun equals(other: Any?): Boolean = this === other ||
        (other is DSHConnectionState &&
            when {
                this is Reconnecting && other is Reconnecting -> attempt == other.attempt
                this is Failed && other is Failed -> message == other.message
                else -> this::class == other::class
            })

    override fun hashCode(): Int = when (this) {
        is Reconnecting -> 31 * 7 + attempt
        is Failed -> 31 * 11 + message.hashCode()
        else -> this::class.hashCode()
    }
}

/**
 * Wire form of the connection state, mirroring the Swift `Codable` synthesis:
 * `{"state":"connected"}` / `{"state":"reconnecting","attempt":2}` /
 * `{"state":"failed","message":"…"}`. Used by the `transport.state` control
 * event the socket pushes into the event stream.
 */
fun DSHConnectionState.toWireJson(): kotlinx.serialization.json.JsonObject =
    kotlinx.serialization.json.buildJsonObject {
        when (this@toWireJson) {
            is DSHConnectionState.Disconnected -> put("state", kotlinx.serialization.json.JsonPrimitive("disconnected"))
            is DSHConnectionState.Connecting -> put("state", kotlinx.serialization.json.JsonPrimitive("connecting"))
            is DSHConnectionState.Connected -> put("state", kotlinx.serialization.json.JsonPrimitive("connected"))
            is DSHConnectionState.Reconnecting -> {
                put("state", kotlinx.serialization.json.JsonPrimitive("reconnecting"))
                put("attempt", kotlinx.serialization.json.JsonPrimitive(attempt))
            }
            is DSHConnectionState.Failed -> {
                put("state", kotlinx.serialization.json.JsonPrimitive("failed"))
                put("message", kotlinx.serialization.json.JsonPrimitive(message))
            }
        }
    }

/** Inverse of [toWireJson]; null for anything malformed, like Swift's throw. */
fun connectionStateFromWire(element: kotlinx.serialization.json.JsonElement): DSHConnectionState? {
    val obj = element as? kotlinx.serialization.json.JsonObject ?: return null
    val name = (obj["state"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: return null
    return when (name) {
        "disconnected" -> DSHConnectionState.Disconnected
        "connecting" -> DSHConnectionState.Connecting
        "connected" -> DSHConnectionState.Connected
        "reconnecting" -> {
            val attempt = (obj["attempt"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.toIntOrNull()
                ?: return null
            DSHConnectionState.Reconnecting(attempt)
        }
        "failed" -> {
            val message = (obj["message"] as? kotlinx.serialization.json.JsonPrimitive)?.content ?: return null
            DSHConnectionState.Failed(message)
        }
        else -> null
    }
}

/** Mirrors `DSHExponentialBackoff`. */
data class DSHExponentialBackoff(
    val initialMillis: Long = 500,
    val maximumMillis: Long = 30_000,
    val multiplier: Double = 2.0,
) {
    fun delayMillisFor(attempt: Int): Long {
        if (attempt <= 0) return 0
        val scaled = initialMillis * Math.pow(multiplier, (attempt - 1).toDouble())
        return minOf(maximumMillis.toLong(), scaled.toLong().coerceAtLeast(0))
    }
}
