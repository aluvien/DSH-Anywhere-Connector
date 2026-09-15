package com.dshanywhere.features.sessions

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.ui.theme.DSHColors
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

// ---------------------------------------------------------------------------
// Color aliases — SwiftUI semantic colours used across SessionListView.
// ---------------------------------------------------------------------------

/** SwiftUI `Color.primary`. */
@Composable
internal fun dshPrimary(): Color = DSHColors.label()

/** SwiftUI `Color.secondary`. */
@Composable
internal fun dshSecondary(): Color = DSHColors.secondaryLabel()

/** SwiftUI `.ultraThinMaterial` / `.thinMaterial` — translucent fill; real blur
 *  is unavailable below API 31 (PORTING-SPEC accepts this approximation). */
@Composable
internal fun dshMaterial(): Color = DSHColors.thinMaterial()

// ---------------------------------------------------------------------------
// Icons — SF Symbol stand-ins (PORTING-SPEC: closest Material match; the
// original symbol name is commented at every call site).
// ---------------------------------------------------------------------------

/**
 * SwiftUI `Image(systemName:).font(.system(size: s))` — SF Symbols scale the
 * glyph with the font size while Compose keeps padding inside the icon box, so
 * the glyph lands slightly smaller within the same frame. Font weight of the
 * SwiftUI symbol is not reproduced.
 */
@Composable
internal fun DSHLocalIcon(
    icon: ImageVector?,
    contentDescription: String?,
    sizePx: Int,
    modifier: Modifier = Modifier,
    tint: Color = dshPrimary(),
) {
    icon?.let {
        Icon(
            it,
            contentDescription = contentDescription,
            tint = tint,
            modifier = modifier.size(sizePx.dp),
        )
    }
}

// ---------------------------------------------------------------------------
// Timestamps — mirrors the static DateFormatters in the Swift rows
// (`HH:mm` for today, `MM/dd` otherwise; input is epoch millis).
// ---------------------------------------------------------------------------

private val dshClockFormatter = SimpleDateFormat("HH:mm", Locale.getDefault())
private val dshDayFormatter = SimpleDateFormat("MM/dd", Locale.getDefault())

internal fun dshIsToday(epochMillis: Long): Boolean {
    val today = Calendar.getInstance()
    val other = Calendar.getInstance().apply { timeInMillis = epochMillis }
    return today.get(Calendar.ERA) == other.get(Calendar.ERA) &&
        today.get(Calendar.YEAR) == other.get(Calendar.YEAR) &&
        today.get(Calendar.DAY_OF_YEAR) == other.get(Calendar.DAY_OF_YEAR)
}

/** Swift rows' `updatedLabel` (empty when `updatedAt <= 0`). */
internal fun dshUpdatedLabel(updatedAt: Long): String {
    if (updatedAt <= 0L) return ""
    val date = Date(updatedAt)
    return if (dshIsToday(updatedAt)) dshClockFormatter.format(date) else dshDayFormatter.format(date)
}

// ---------------------------------------------------------------------------
// Anchored menus
//
// SwiftUI `Menu { items } label: { … }` opens a system pull-down anchored to
// its label. Compose's `DropdownMenu` anchors to the Box that hosts it, so the
// wrappers below keep the label tightly sized inside a wrapping Box.
// ---------------------------------------------------------------------------

/** A `DropdownMenu` styled like the iOS anchored menu (fixed width, solid
 *  systemBackground container — iOS uses translucent material). */
@Composable
internal fun DSHDropdownMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    width: Dp,
    offsetX: Int = 6,
    offsetY: Int = 6,
    content: @Composable ColumnScope.() -> Unit,
) {
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        offset = DpOffset(offsetX.dp, offsetY.dp),
        modifier = Modifier.width(width),
        shape = RoundedCornerShape(14.dp),
        containerColor = DSHColors.systemBackground(),
        content = { Column { content() } },
    )
}

// ---------------------------------------------------------------------------
// Menu rows — SwiftUI `Label(text, systemImage:)` inside `Menu`.
// ---------------------------------------------------------------------------

@Composable
internal fun DSHMenuRow(
    icon: ImageVector?,
    text: String,
    onClick: () -> Unit,
    destructive: Boolean = false,
    checkmark: Boolean = false,
) {
    val tint = if (destructive) DSHColors.systemRed() else dshPrimary()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickableRow(onClick)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
            if (checkmark) {
                DSHLocalIcon(Icons.Filled.Check, null, 15, tint = tint)
            } else {
                DSHLocalIcon(icon, null, 17, tint = tint)
            }
        }
        Spacer(Modifier.width(10.dp))
        Text(text, fontSize = 16.sp, color = tint)
    }
}

/** SwiftUI `Toggle(…) { Label(…) }` rendered inside a menu. */
@Composable
internal fun DSHMenuToggleRow(
    icon: ImageVector?,
    text: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickableRow { onCheckedChange(!checked) }
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(22.dp), contentAlignment = Alignment.Center) {
            DSHLocalIcon(icon, null, 17, tint = dshPrimary())
        }
        Spacer(Modifier.width(10.dp))
        Text(text, fontSize = 16.sp, color = dshPrimary(), modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}

/** SwiftUI `Divider()` inside a menu. */
@Composable
internal fun DSHMenuDivider() {
    HorizontalDivider(
        modifier = Modifier.padding(vertical = 4.dp),
        thickness = 0.7.dp,
        color = DSHColors.separator(),
    )
}

/** SwiftUI `Section("title") { … }` header inside a menu. */
@Composable
internal fun DSHMenuSectionHeader(text: String) {
    Text(
        text,
        fontSize = 12.sp,
        color = dshSecondary(),
        modifier = Modifier.padding(start = 14.dp, end = 14.dp, top = 8.dp, bottom = 4.dp),
    )
}

internal fun Modifier.clickableRow(onClick: () -> Unit): Modifier =
    clickable(onClick = onClick)

/**
 * Row scaffold with a long-press `.contextMenu`. [content] receives the row
 * body; the whole row is the tap target ([onClick]) and the long-press target
 * (menu). The popover anchors to the row Box and is offset toward the leading
 * padding so it reads as attached to the row content.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun DSHRowContextMenu(
    expanded: Boolean,
    onExpand: () -> Unit,
    onDismissRequest: () -> Unit,
    onClick: () -> Unit,
    menuOffsetX: Int,
    menuWidth: Dp,
    menuContent: @Composable ColumnScope.() -> Unit,
    content: @Composable () -> Unit,
) {
    Box(Modifier.fillMaxWidth()) {
        Box(
            Modifier
                .fillMaxWidth()
                .combinedClickable(onClick = onClick, onLongClick = onExpand),
        ) { content() }
        DSHDropdownMenu(
            expanded = expanded,
            onDismissRequest = onDismissRequest,
            width = menuWidth,
            offsetX = menuOffsetX,
            offsetY = 56,
            content = menuContent,
        )
    }
}

/** SwiftUI `Rectangle().fill(c).frame(height: 1)` inside an HStack. */
@Composable
internal fun dshHorizontalHairline(color: Color, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(color))
}

/** SwiftUI `Divider().frame(height: h)` inside an HStack — a vertical hairline. */
@Composable
internal fun dshVerticalHairline(height: Dp, color: Color) {
    Box(Modifier.width(0.7.dp).height(height).background(color))
}
