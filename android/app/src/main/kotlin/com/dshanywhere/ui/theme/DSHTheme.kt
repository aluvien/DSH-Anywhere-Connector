package com.dshanywhere.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

@Composable private fun dark(): Boolean = isSystemInDarkTheme()

/**
 * iOS system-color equivalents so the Android UI can track the SwiftUI design
 * 1:1. Dark-mode values use the standard iOS system (dark) palette.
 */
object DSHColors {
    @Composable fun systemBackground(): Color = if (dark()) Color(0xFF000000) else Color(0xFFFFFFFF)
    @Composable fun secondarySystemBackground(): Color = if (dark()) Color(0xFF1C1C1E) else Color(0xFFF2F2F7)
    @Composable fun tertiarySystemBackground(): Color = if (dark()) Color(0xFF2C2C2E) else Color(0xFFFFFFFF)
    @Composable fun systemGroupedBackground(): Color = if (dark()) Color(0xFF000000) else Color(0xFFF2F2F7)
    @Composable fun secondarySystemGroupedBackground(): Color = if (dark()) Color(0xFF1C1C1E) else Color(0xFFFFFFFF)

    @Composable fun label(): Color = if (dark()) Color(0xFFFFFFFF) else Color(0xFF000000)
    @Composable fun secondaryLabel(): Color =
        if (dark()) Color(0xFFF5F5F7).copy(alpha = 0.60f) else Color(0xFF3C3C43).copy(alpha = 0.60f)
    @Composable fun tertiaryLabel(): Color =
        if (dark()) Color(0xFFF5F5F7).copy(alpha = 0.30f) else Color(0xFF3C3C43).copy(alpha = 0.30f)
    @Composable fun quaternaryLabel(): Color =
        if (dark()) Color(0xFFF5F5F7).copy(alpha = 0.18f) else Color(0xFF3C3C43).copy(alpha = 0.18f)

    @Composable fun separator(): Color =
        if (dark()) Color(0xFFF5F5F7).copy(alpha = 0.16f) else Color(0xFF3C3C43).copy(alpha = 0.18f)

    @Composable fun systemGray(): Color = if (dark()) Color(0xFF8E8E93) else Color(0xFF8E8E93)
    @Composable fun systemGray2(): Color = if (dark()) Color(0xFF636366) else Color(0xFFAEAEB2)
    @Composable fun systemGray3(): Color = if (dark()) Color(0xFF48484A) else Color(0xFFC7C7CC)
    @Composable fun systemGray4(): Color = if (dark()) Color(0xFF3A3A3C).copy(alpha = 0.85f) else Color(0xFFD1D1D6)
    @Composable fun systemGray5(): Color = if (dark()) Color(0xFF2C2C2E) else Color(0xFFE5E5EA)
    @Composable fun systemGray6(): Color = if (dark()) Color(0xFF1C1C1E) else Color(0xFFF2F2F7)

    @Composable fun systemBlue(): Color = if (dark()) Color(0xFF0A84FF) else Color(0xFF007AFF)
    @Composable fun systemGreen(): Color = if (dark()) Color(0xFF30D158) else Color(0xFF34C759)
    @Composable fun systemRed(): Color = if (dark()) Color(0xFFFF453A) else Color(0xFFFF3B30)
    @Composable fun systemOrange(): Color = if (dark()) Color(0xFFFF9F0A) else Color(0xFFFF9500)
    @Composable fun systemYellow(): Color = if (dark()) Color(0xFFFFD60A) else Color(0xFFFFCC00)
    @Composable fun systemPurple(): Color = if (dark()) Color(0xFFBF5AF2) else Color(0xFFAF52DE)
    @Composable fun systemPink(): Color = if (dark()) Color(0xFFFF375F) else Color(0xFFFF2D55)
    @Composable fun systemTeal(): Color = if (dark()) Color(0xFF64D2FF) else Color(0xFF30B0C7)
    @Composable fun systemMint(): Color = if (dark()) Color(0xFF63E6E2) else Color(0xFF00C7BE)
    @Composable fun systemIndigo(): Color = if (dark()) Color(0xFF5E5CE6) else Color(0xFF5855D1)

    /** `.ultraThinMaterial` approximation: translucent sheet colour. */
    @Composable fun thinMaterial(): Color = if (dark()) Color(0xFF1C1C1E).copy(alpha = 0.72f)
        else Color(0xFFF7F7F7).copy(alpha = 0.78f)

    // Brand gradients used on the home header (verbatim from SessionListView).
    val greenStart = Color(0xFF05B847)
    val greenEnd = Color(0xFF058A38)
    val purpleStart = Color(0xFFBC40FA)
    val purpleEnd = Color(0xFFFA4CC7)
    val claudeOrange = Color(0xFFED6E45)
    val claudeBackdrop = Color(0xFF291A17)

}

private val DSHLightScheme = lightColorScheme(
    primary = Color(0xFF007AFF),
    onPrimary = Color.White,
    surface = Color.White,
    onSurface = Color(0xFF000000),
    background = Color(0xFFF2F2F7),
    onBackground = Color(0xFF000000),
)

private val DSHDarkScheme = darkColorScheme(
    primary = Color(0xFF0A84FF),
    onPrimary = Color.White,
    surface = Color(0xFF1C1C1E),
    onSurface = Color.White,
    background = Color(0xFF000000),
    onBackground = Color.White,
)

@Composable
fun DSHTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = if (isSystemInDarkTheme()) DSHDarkScheme else DSHLightScheme,
        typography = DSHTypography,
        content = content,
    )
}

/** SF Pro is unavailable on Android; the system default (Roboto) keeps metrics. */
val DSHTypography = Typography()
