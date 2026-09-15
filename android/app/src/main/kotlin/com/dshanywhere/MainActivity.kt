package com.dshanywhere

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.dshanywhere.app.DSHAppModel
import com.dshanywhere.app.DSHPreviewTransport
import com.dshanywhere.core.protocol.DSHLanguage
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.features.conversation.ConversationScreen
import com.dshanywhere.features.pairing.PairingScreen
import com.dshanywhere.features.sessions.SessionListScreen
import com.dshanywhere.ui.common.DSHErrorAlert
import com.dshanywhere.ui.theme.DSHTheme

val LocalAppModel = compositionLocalOf<DSHAppModel> {
    error("No DSHAppModel provided")
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val model = createAppModel(this, intent)
        DSHLocalization.language = model.language

        setContent {
            // Reading DSHLocalization.language (snapshot state) here makes the
            // whole tree re-localize immediately when the preference changes,
            // mirroring the SwiftUI `.environment(\.locale, …)` root modifier.
            @Suppress("UNUSED_EXPRESSION")
            DSHLocalization.language
            DSHAppRoot(model)
        }
    }
}

/**
 * Debug launch fixtures, mirroring iOS's `--dsh-preview-*` launch arguments:
 * `adb shell am start -n com.dshanywhere/.MainActivity --es dsh-preview conversation`
 */
private fun createAppModel(context: Context, intent: Intent): DSHAppModel {
    if (BuildConfig.DEBUG) {
        when (intent.getStringExtra("dsh-preview")) {
            "conversation" -> return DSHAppModel.preview(context)
            "home" -> return DSHAppModel.previewHome(context)
            "home-grouped" -> return DSHAppModel.previewHome(context, grouped = true)
            "home-unreachable" -> return DSHAppModel.previewHomeUnreachable(context)
        }
    }
    return DSHAppModel(context)
}

@Composable
fun DSHAppRoot(model: DSHAppModel) {
    val navController = rememberNavController()
    DSHTheme {
        CompositionLocalProvider(LocalAppModel provides model) {
            // Mirrors DSHRootView: pairing gate, single navigation stack, and a
            // global error alert fed by model.errorMessage.
            if (model.isPaired) {
                NavHost(
                    navController = navController,
                    startDestination = "home",
                ) {
                    composable("home") {
                        SessionListScreen(
                            onOpenSession = { id ->
                                model.selectedSessionID = id
                                navController.navigate("conversation/$id")
                            },
                        )
                    }
                    composable("conversation/{sessionId}") { entry ->
                        val sessionId = entry.arguments?.getString("sessionId").orEmpty()
                        ConversationScreen(sessionID = sessionId)
                    }
                }
            } else {
                PairingScreen()
            }

            DSHErrorAlert(
                message = model.errorMessage,
                onDismiss = { model.errorMessage = null },
            )

            // `.task { if model.isPaired { model.connect() } }` in SwiftUI:
            // one connection attempt per composition of a paired session.
            var didConnect by remember(model.isPaired) { mutableStateOf(false) }
            androidx.compose.runtime.LaunchedEffect(model.isPaired) {
                if (model.isPaired && !didConnect) {
                    didConnect = true
                    model.connect()
                }
            }
        }
    }
}
