package com.dshanywhere.features.conversation

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import kotlinx.coroutines.launch

/**
 * Clipboard helper shared by the copy-code button and the copy-message button.
 * SwiftUI equivalent: `UIPasteboard.general.string = value`.
 *
 * Returns a non-suspending callback so callers can fire-and-forget from a
 * click handler; the write itself runs on the composition scope.
 */
@Composable
internal fun rememberCopyToClipboard(): (String) -> Unit {
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    return remember(clipboard, scope) {
        { value -> scope.launch { clipboard.setText(AnnotatedString(value)) } }
    }
}

/**
 * SwiftUI: `compactNumber` / `compact` from `UsageFooter` and
 * `ThinkingDisclosure` — "1.2M" / "12.3K" / "456".
 */
internal fun dshCompactNumber(value: Double?): String {
    value ?: return "0"
    return when {
        value >= 1_000_000 -> String.format(java.util.Locale.US, "%.1fM", value / 1_000_000)
        value >= 1_000 -> String.format(java.util.Locale.US, "%.1fK", value / 1_000)
        else -> value.toInt().toString()
    }
}

/** SwiftUI: `.capitalized` applied to `tool.status` and effort ids. */
internal fun dshCapitalized(value: String): String =
    value.replaceFirstChar {
        if (it.isLowerCase()) it.titlecase(java.util.Locale.getDefault()) else it.toString()
    }
