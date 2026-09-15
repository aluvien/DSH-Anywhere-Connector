package com.dshanywhere.core.store

import android.content.Context
import com.dshanywhere.core.network.DSHRemoteProfile
import com.dshanywhere.core.protocol.DSHJson

/**
 * The Macs this device is paired with. Mirrors
 * ios/DSHAnywhere/Core/Store/DSHProfileStore.swift: an ordered list plus the
 * active machine; device tokens live in the token store keyed by deviceId, so
 * several machines' credentials can coexist without further changes.
 */
class DSHProfileStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    val profiles: List<DSHRemoteProfile> get() = load()

    val activeMachineId: String?
        get() = prefs.getString(KEY_ACTIVE, null) ?: load().firstOrNull()?.machineId

    val activeProfile: DSHRemoteProfile?
        get() {
            val all = load()
            val id = activeMachineId ?: return all.firstOrNull()
            return all.firstOrNull { it.machineId == id } ?: all.firstOrNull()
        }

    /** Adds or replaces one machine, keeping pairing order stable. */
    fun upsert(profile: DSHRemoteProfile, makeActive: Boolean = true): List<DSHRemoteProfile> {
        val all = load().filterNot { it.machineId == profile.machineId } + profile
        save(all)
        if (makeActive) setActive(profile.machineId)
        return all
    }

    /** Removes one machine, moving the active selection to a remaining Mac. */
    fun remove(machineId: String): List<DSHRemoteProfile> {
        val all = load().filterNot { it.machineId == machineId }
        save(all)
        if (activeMachineId == machineId) {
            val next = all.firstOrNull()
            if (next != null) setActive(next.machineId)
            else prefs.edit().remove(KEY_ACTIVE).apply()
        }
        return all
    }

    fun setActive(machineId: String) {
        prefs.edit().putString(KEY_ACTIVE, machineId).apply()
    }

    private fun load(): List<DSHRemoteProfile> {
        val raw = prefs.getString(KEY_PROFILES, null) ?: return emptyList()
        return runCatching {
            DSHJson.decodeFromString(
                kotlinx.serialization.builtins.ListSerializer(DSHRemoteProfile.serializer()), raw,
            )
        }.getOrDefault(emptyList())
    }

    private fun save(profiles: List<DSHRemoteProfile>) {
        val raw = DSHJson.encodeToString(
            kotlinx.serialization.builtins.ListSerializer(DSHRemoteProfile.serializer()), profiles,
        )
        prefs.edit().putString(KEY_PROFILES, raw).apply()
    }

    companion object {
        const val PREFERENCES = "dsh-anywhere"
        const val KEY_PROFILES = "dsh-anywhere.relay-profiles"
        const val KEY_ACTIVE = "dsh-anywhere.active-machine-id"
    }
}
