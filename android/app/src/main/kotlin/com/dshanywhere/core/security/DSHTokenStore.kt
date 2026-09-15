package com.dshanywhere.core.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores the per-device bearer token. Mirrors the `DSHTokenStore` protocol in
 * ios/DSHAnywhere/Core/Security/DSHKeychainTokenStore.swift.
 */
interface DSHTokenStore {
    fun save(token: String, account: String)
    fun read(account: String): String?
    fun delete(account: String)
}

/**
 * Android-key-backed replacement for the iOS Keychain: the AES key lives in
 * the AndroidKeyStore (non-exportable, requires no screen unlock on use),
 * while ciphertext sits in an app-private file.
 */
class DSHKeystoreTokenStore(context: Context) : DSHTokenStore {
    private val file = java.io.File(context.filesDir, "dsh-tokens.bin")
    private val lock = Any()

    override fun save(token: String, account: String) = synchronized(lock) {
        val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
        }
        val ciphertext = cipher.doFinal(token.toByteArray(Charsets.UTF_8))
        val record = encode(iv + ciphertext)
        val records = readAll().toMutableMap()
        records[account] = record
        writeAll(records)
    }

    override fun read(account: String): String? = synchronized(lock) {
        val record = readAll()[account] ?: return null
        runCatching {
            val raw = decode(record)
            val iv = raw.copyOfRange(0, 12)
            val ciphertext = raw.copyOfRange(12, raw.size)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(TAG_BITS, iv))
            }
            String(cipher.doFinal(ciphertext), Charsets.UTF_8)
        }.getOrNull()
    }

    override fun delete(account: String) = synchronized(lock) {
        val records = readAll().toMutableMap()
        records.remove(account)
        writeAll(records)
    }

    // Records are length-prefixed so arbitrary account names cannot collide
    // with the line format; a base64 record never contains a newline anyway.
    private fun readAll(): Map<String, String> {
        if (!file.exists()) return emptyMap()
        return runCatching {
            file.readLines().mapNotNull { line ->
                val index = line.indexOf(':')
                if (index <= 0) return@mapNotNull null
                line.substring(0, index) to line.substring(index + 1)
            }.toMap()
        }.getOrDefault(emptyMap())
    }

    private fun writeAll(records: Map<String, String>) {
        file.writeText(records.entries.joinToString("\n") { "${it.key}:${it.value}" })
    }

    private fun encode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun decode(text: String): ByteArray =
        Base64.decode(text, Base64.NO_WRAP)

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "com.dshanywhere.auth"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_BITS = 128
    }
}

/** Lightweight in-memory implementation useful for previews and unit tests. */
class DSHInMemoryTokenStore : DSHTokenStore {
    private val values = mutableMapOf<String, String>()

    @Synchronized
    override fun save(token: String, account: String) {
        values[account] = token
    }

    @Synchronized
    override fun read(account: String): String? = values[account]

    @Synchronized
    override fun delete(account: String) {
        values.remove(account)
    }
}
