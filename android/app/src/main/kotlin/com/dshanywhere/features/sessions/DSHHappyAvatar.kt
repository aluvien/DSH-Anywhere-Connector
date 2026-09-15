package com.dshanywhere.features.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.dshanywhere.ui.theme.DSHColors
import kotlin.math.max

/// Ported 1:1 from `DSHHappyAvatar` in ios/DSHAnywhere/Features/Sessions/SessionListView.swift.
///
/// The small project avatar used by Happy's flat session list. DSH Anywhere
/// does not receive a project-avatar URL from the Harness, so we keep the
/// geometry stable and use a deterministic, branded mark.
///
/// NOTE: The Swift original is a *static* drawing — it contains no
/// breathing/rotation animation and no green/purple state switch; the only
/// "two states" are the constant green gradient disc plus the constant purple
/// ribbons, and the sunburst badge is always claude-orange. Ported as-is.
///
/// iOS usage caveat: in the Swift file `HappySessionRow` (the only consumer)
/// is itself never referenced, so this avatar does not appear on screen today;
/// it is ported for completeness.

// The sun core `Color(red: 0.22, green: 0.10, blue: 0.09)` is not part of the
// shared palette; value derived verbatim from the iOS initialiser.
private val DSHAvatarSunCore = Color(0xFF381A17)

@Composable
fun DSHHappyAvatar(
    size: Dp,
    faded: Boolean = false,
    modifier: Modifier = Modifier,
) {
    val s = size.value
    Box(
        modifier
            .size(size)
            .alpha(if (faded) 0.45f else 1f), // Swift: `.opacity(faded ? 0.45 : 1)`
        contentAlignment = Alignment.Center,
    ) {
        // --- disc ------------------------------------------------------------
        Box(
            Modifier
                .size(size)
                .clip(CircleShape), // Swift: `.clipShape(Circle())`
            contentAlignment = Alignment.Center,
        ) {
            // LinearGradient(topLeading → bottomTrailing) — Compose's default
            // linear gradient direction (zero → infinite) matches.
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.linearGradient(
                            listOf(DSHColors.greenStart, DSHColors.greenEnd),
                        ),
                    ),
            )
            // Happy's project mark: three slightly organic purple ribbons.
            // Swift: ForEach(0..<3) capsule, width size*0.60,
            // height max(3, size*0.12), rotation -3/0/+3°, offset y (index-1)*0.16s.
            for (index in 0 until 3) {
                val rotation = when (index) {
                    1 -> 0f
                    0 -> -3f
                    else -> 3f
                }
                Box(
                    Modifier
                        .offset {
                            IntOffset(
                                0,
                                ((index - 1) * s * 0.16f).dp.roundToPx(),
                            )
                        }
                        .size(width = (s * 0.60f).dp, height = max(3f, s * 0.12f).dp)
                        // SwiftUI applies rotationEffect then offsets in a
                        // ZStack; rotating the wrapper and offsetting the
                        // rotated capsule below is geometrically equivalent.
                        .rotate(rotation)
                        .clip(CircleShape)
                        // LinearGradient(leading → trailing)
                        .background(Brush.horizontalGradient(listOf(DSHColors.purpleStart, DSHColors.purpleEnd))),
                )
            }
            // overlay { Circle().stroke(Color.white.opacity(0.14), lineWidth: max(0.5, size*0.018)) }
            Box(
                Modifier
                    .fillMaxSize()
                    .border(
                        max(0.5f, s * 0.018f).dp,
                        Color.White.copy(alpha = 0.14f),
                        CircleShape,
                    ),
            )
        }

        // --- small orange sunburst badge (lower-right activity marker) -----
        // Swift: `.frame(width: size*0.30, height: size*0.30)
        //         .background(Color(0.16,0.08,0.08), in: Circle())
        //         .overlay{ stroke black.opacity(0.55) }
        //         .offset(x: size*0.40, y: size*0.40)`
        Box(
            Modifier
                .size((s * 0.30f).dp)
                .offset {
                    IntOffset(
                        (s * 0.40f).dp.roundToPx(),
                        (s * 0.40f).dp.roundToPx(),
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                Modifier
                    .size((s * 0.30f).dp)
                    .background(DSHColors.claudeBackdrop, CircleShape),
            )
            // ForEach(0..<8): capsule w=max(1.5, size*0.045) h=size*0.24, filled
            // claude orange, rotated index*45°. The rays are *not* clipped by
            // the badge circle in SwiftUI, so no clip here either.
            for (index in 0 until 8) {
                Box(
                    Modifier
                        .size(width = max(1.5f, s * 0.045f).dp, height = (s * 0.24f).dp)
                        .rotate(index * 45f)
                        .clip(CircleShape)
                        .background(DSHColors.claudeOrange),
                )
            }
            Box(
                Modifier
                    .size((s * 0.16f).dp)
                    .background(DSHAvatarSunCore, CircleShape),
            )
            Box(
                Modifier
                    .size((s * 0.30f).dp)
                    .border(
                        max(0.5f, s * 0.018f).dp,
                        Color.Black.copy(alpha = 0.55f),
                        CircleShape,
                    ),
            )
        }
    }
}
