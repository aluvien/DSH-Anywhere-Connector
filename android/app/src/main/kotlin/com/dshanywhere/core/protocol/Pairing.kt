package com.dshanywhere.core.protocol

import java.net.URLDecoder

/**
 * Scanned `dshanywhere://pair` payload. Mirrors `parsePairingLink` in
 * packages/protocol so the QR format keeps a single definition across the
 * TypeScript connector and this client.
 *
 * Exactly one credential authorises a pairing: the long-lived secret, or a
 * single-use code minted by the Mac. The sealed type keeps "both" and "neither"
 * unrepresentable.
 */
sealed class DSHPairingCredential {
    data class Secret(val value: String) : DSHPairingCredential()
    data class Code(val value: String) : DSHPairingCredential()

    companion object {
        /**
         * Codes are 8 characters drawn from an alphabet without 0/O/1/I/L;
         * secrets are 43-character base64url. The lengths cannot overlap, so a
         * single text field can accept either without asking the user to pick
         * a mode.
         */
        fun detect(raw: String): DSHPairingCredential? {
            val trimmed = raw.trim { it == ' ' || it == '\n' || it == '\r' || it == '\t' }
            if (trimmed.isEmpty()) return null
            val upper = trimmed.uppercase()
            val isCode = upper.length == 8 && upper.all { CODE_ALPHABET.contains(it) }
            return if (isCode) Code(upper) else Secret(trimmed)
        }

        const val CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    }
}

data class DSHPairingLink(
    val relay: String,
    val machineId: String,
    val credential: DSHPairingCredential,
) {
    companion object {
        /**
         * Returns null for anything that is not a complete pairing link, so the
         * scanner can keep looking instead of filling in half a credential.
         */
        fun parse(urlString: String): DSHPairingLink? {
            val trimmed = urlString.trim { it == ' ' || it == '\n' || it == '\r' || it == '\t' }
            val schemeSep = trimmed.indexOf(':')
            if (schemeSep <= 0) return null
            if (trimmed.substring(0, schemeSep).lowercase() != "dshanywhere") return null

            // Only the query matters; split by hand to avoid URL semantics on
            // a custom scheme.
            val query = trimmed.substringAfter('?', "")
            if (query.isEmpty()) return null
            val params = mutableMapOf<String, String>()
            for (pair in query.split('&')) {
                if (pair.isEmpty()) continue
                val key = pair.substringBefore('=', pair)
                val rawValue = if (pair.contains('=')) pair.substringAfter('=') else ""
                val decoded = runCatching {
                    URLDecoder.decode(rawValue, "UTF-8").replace('+', ' ')
                }.getOrNull() ?: continue
                // Swift's URLComponents does not translate '+' to space in a
                // custom-scheme query; undo URLDecoder's form-style bias.
                params.putIfAbsent(key, decoded.trim { it == ' ' || it == '\n' || it == '\r' || it == '\t' })
            }

            val relay = params["relay"]?.takeIf { it.isNotEmpty() } ?: return null
            val machineId = params["machineId"]?.takeIf { it.isNotEmpty() } ?: return null
            val relayScheme = relay.substringBefore("://", "").lowercase()
            if (relayScheme != "https" && relayScheme != "http") return null

            // A link carrying both is ambiguous; the code wins, matching
            // parsePairingLink in packages/protocol.
            val code = params["code"]?.uppercase() ?: ""
            val secret = params["secret"] ?: ""
            val credential: DSHPairingCredential = if (code.isNotEmpty()) {
                DSHPairingCredential.Code(code)
            } else if (secret.isNotEmpty()) {
                DSHPairingCredential.Secret(secret)
            } else {
                return null
            }
            return DSHPairingLink(relay = relay, machineId = machineId, credential = credential)
        }
    }
}
