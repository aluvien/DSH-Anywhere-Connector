package com.dshanywhere.core.protocol

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** The language the interface is shown in. Mirrors `DSHLanguage`. */
enum class DSHLanguage(val rawValue: String) {
    System("system"),
    SimplifiedChinese("zh-Hans"),
    English("en"),
    ;

    /** null means "follow the device". */
    val localeTag: String? get() = if (this == System) null else rawValue

    /** Each option is written in its own language, so it stays readable even */
    val displayName: String
        get() = when (this) {
            System -> DSHLocalization.string("Follow System")
            SimplifiedChinese -> "简体中文"
            English -> "English"
        }

    companion object {
        fun fromRaw(value: String?): DSHLanguage =
            entries.firstOrNull { it.rawValue == value } ?: System
    }
}

/**
 * Localizes strings built outside the composition tree. Mirrors
 * `DSHLocalization`: keys are the English literals themselves, exactly like
 * iOS where Localizable.xcstrings keys are English text; the generated
 * [ZH_TRANSLATIONS] map carries the zh-Hans values.
 */
object DSHLocalization {
    var language: DSHLanguage by mutableStateOf(DSHLanguage.System)

    private val followSystemChinese: Boolean
        get() = java.util.Locale.getDefault().language == "zh"

    val isChinese: Boolean
        get() = when (language) {
            DSHLanguage.SimplifiedChinese -> true
            DSHLanguage.English -> false
            DSHLanguage.System -> followSystemChinese
        }

    fun string(key: String): String {
        if (!isChinese) return key
        return ZH_TRANSLATIONS[key] ?: key
    }

    /** Formats iOS-style `%@` placeholders in a localized string. */
    fun format(key: String, vararg args: Any?): String {
        var text = string(key)
        for (arg in args) {
            text = text.replaceFirst("%@", arg?.toString() ?: "")
        }
        return text
    }
}
