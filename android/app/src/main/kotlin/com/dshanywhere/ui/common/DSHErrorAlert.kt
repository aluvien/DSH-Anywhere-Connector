package com.dshanywhere.ui.common

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.dshanywhere.core.protocol.DSHLocalization

/**
 * Mirrors the SwiftUI `.alert("Something went wrong", isPresented:)` on the
 * root view: one shared error dialog bound to `model.errorMessage`.
 */
@Composable
fun DSHErrorAlert(message: String?, onDismiss: () -> Unit) {
    val text = message ?: return
    Dialog(onDismissRequest = onDismiss) {
        Surface(
            shape = RoundedCornerShape(26.dp),
            color = MaterialTheme.colorScheme.surface,
            tonalElevation = 6.dp,
        ) {
            Column(Modifier.fillMaxWidth().padding(20.dp)) {
                Text(
                    DSHLocalization.string("Something went wrong"),
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text.ifEmpty { DSHLocalization.string("Unknown error") },
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                    modifier = Modifier.padding(top = 8.dp),
                )
                TextButton(
                    onClick = onDismiss,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                ) {
                    Text(DSHLocalization.string("OK"))
                }
            }
        }
    }
}
