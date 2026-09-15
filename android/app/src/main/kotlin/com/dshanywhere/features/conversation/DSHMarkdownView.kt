package com.dshanywhere.features.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dshanywhere.core.protocol.DSHLocalization
import com.dshanywhere.core.protocol.DSHMarkdown
import com.dshanywhere.core.protocol.DSHMarkdownBlock
import com.dshanywhere.ui.theme.DSHColors
import kotlinx.coroutines.delay

/**
 * Ports of the private `MarkdownBlockText`, `MarkdownBlockView` and
 * `MarkdownTableView` structs from ConversationView.swift. Block structure
 * comes from `DSHMarkdown.blocks(text)`; inline markup is applied here.
 */

// SF Text styles used by the SwiftUI view, converted to explicit sizes
// (body 17, callout 16, subheadline 15, footnote 13, caption 12, caption2 11).
internal val MdBody = TextStyle(fontSize = 17.sp)
internal val MdCaption = TextStyle(fontSize = 12.sp)
internal val MdCaptionSemibold = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
internal val MdCaption2 = TextStyle(fontSize = 11.sp)
internal val MdFootnoteMono = TextStyle(fontSize = 13.sp, fontFamily = FontFamily.Monospace)

/** SwiftUI: `MarkdownBlockText` — VStack(alignment: .leading, spacing: 10). */
@Composable
internal fun MarkdownBlockText(text: String) {
    val blocks = remember(text) { DSHMarkdown.blocks(text) }
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
        horizontalAlignment = Alignment.Start,
    ) {
        blocks.forEach { block -> MarkdownBlockView(block) }
    }
}

/** SwiftUI: `MarkdownBlockView`. */
@Composable
internal fun MarkdownBlockView(block: DSHMarkdownBlock) {
    when (val kind = block.kind) {
        is DSHMarkdownBlock.Kind.Heading -> {
            // .headline == 17pt semibold; .subheadline.weight(.semibold) == 15pt semibold.
            val style = if (kind.level <= 2) {
                TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            } else {
                TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            DshInlineText(kind.text, modifier = Modifier.padding(top = 2.dp), style = style)
        }

        is DSHMarkdownBlock.Kind.Paragraph -> {
            DshInlineText(kind.text, style = MdBody)
        }

        is DSHMarkdownBlock.Kind.Code -> {
            CodeBlockView(language = kind.language, body = kind.body)
        }

        is DSHMarkdownBlock.Kind.Bullets -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                kind.items.forEach { item ->
                    // SwiftUI: HStack(alignment: .firstTextBaseline, spacing: 6).
                    // This Compose build has no Alignment.FirstBaseline; the
                    // surviving API is RowScope.alignByBaseline() on the children.
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text(
                            "•",
                            style = MdBody,
                            color = DSHColors.secondaryLabel(),
                            modifier = Modifier.alignByBaseline(),
                        )
                        DshInlineText(item, style = MdBody, modifier = Modifier.alignByBaseline())
                    }
                }
            }
        }

        is DSHMarkdownBlock.Kind.Numbers -> {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                kind.items.forEachIndexed { index, item ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        // SwiftUI: Text("\(index + 1).").monospacedDigit()
                        Text(
                            "${index + 1}.",
                            style = MdBody.copy(
                                color = DSHColors.secondaryLabel(),
                                fontFamily = FontFamily.Monospace,
                            ),
                            modifier = Modifier.alignByBaseline(),
                        )
                        DshInlineText(item, style = MdBody, modifier = Modifier.alignByBaseline())
                    }
                }
            }
        }

        is DSHMarkdownBlock.Kind.Quote -> {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    // Height bound to the text so the 3pt bar matches it
                    // (SwiftUI Rectangle stretches to the HStack height).
                    .height(IntrinsicSize.Min),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // SwiftUI: Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Box(
                    Modifier
                        .width(3.dp)
                        .fillMaxHeight()
                        .background(DSHColors.secondaryLabel().copy(alpha = 0.4f)),
                )
                DshInlineText(
                    kind.text,
                    style = MdBody.copy(color = DSHColors.secondaryLabel()),
                )
            }
        }

        is DSHMarkdownBlock.Kind.Table -> {
            MarkdownTableView(header = kind.header, rows = kind.rows)
        }

        DSHMarkdownBlock.Kind.Divider -> {
            HorizontalDivider(color = DSHColors.separator())
        }
    }
}

/** Fenced code block: language tag + copy button + sideways-scrolling mono body. */
@Composable
private fun CodeBlockView(language: String?, body: String) {
    var copied by remember(body) { mutableStateOf(false) }
    // SwiftUI: `.onChange(of: copied)` resets the button two seconds later.
    if (copied) {
        LaunchedEffect(copied) {
            delay(2_000)
            copied = false
        }
    }
    val copy = rememberCopyToClipboard()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(
                // SwiftUI: Color(.tertiarySystemBackground), corner radius 10.
                DSHColors.tertiarySystemBackground(),
                RoundedCornerShape(10.dp),
            )
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            if (!language.isNullOrEmpty()) {
                Text(language, style = MdCaption2, color = DSHColors.secondaryLabel())
            }
            Spacer(Modifier.weight(1f).padding(start = 8.dp))
            // SwiftUI: Label(copied ? "Copied" : "Copy", systemImage: "checkmark"/"doc.on.doc")
            Row(
                modifier = Modifier.clickable {
                    copy(body)
                    copied = true
                },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(
                    imageVector = if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
                    contentDescription = if (copied) {
                        DSHLocalization.string("Code copied")
                    } else {
                        DSHLocalization.string("Copy code")
                    },
                    modifier = Modifier.width(11.dp).height(11.dp),
                    tint = DSHColors.secondaryLabel(),
                )
                Text(
                    if (copied) DSHLocalization.string("Copied") else DSHLocalization.string("Copy"),
                    style = MdCaption2,
                    color = DSHColors.secondaryLabel(),
                )
            }
        }
        // SwiftUI: ScrollView(.horizontal) { Text(body).font(.system(.footnote, design: .monospaced)) }
        Box(Modifier.horizontalScroll(rememberScrollState())) {
            Text(body, style = MdFootnoteMono)
        }
    }
}

/**
 * SwiftUI: `MarkdownTableView` — `Grid(alignment: .leading, horizontalSpacing:
 * 14, verticalSpacing: 6)` inside a horizontal `ScrollView`, on a tertiary
 * background.
 *
 * SwiftUI: no direct Compose equivalent in this Compose version (the old
 * `Table` composable is gone), so columns are equal-weight cells: columns stay
 * rectangular and lines up 1:1 like the iOS `Grid`. Wide tables wrap instead
 * of scrolling sideways.
 */
@Composable
private fun MarkdownTableView(header: List<String>, rows: List<List<String>>) {
    val columns = header.size.coerceAtLeast(1)
    fun padded(row: List<String>): List<String> =
        if (row.size >= columns) row.take(columns) else row + List(columns - row.size) { "" }

    Column(
        Modifier
            .fillMaxWidth()
            .background(
                DSHColors.tertiarySystemBackground(),
                RoundedCornerShape(10.dp),
            )
            .padding(10.dp),
    ) {
        Row(Modifier.fillMaxWidth()) {
            header.forEach { cell ->
                DshInlineText(
                    cell,
                    style = MdCaptionSemibold,
                    modifier = Modifier.weight(1f).padding(end = 14.dp, bottom = 6.dp),
                )
            }
        }
        // SwiftUI: Divider().gridCellColumns(columns)
        HorizontalDivider(color = DSHColors.separator(), modifier = Modifier.padding(bottom = 6.dp))
        rows.forEach { row ->
            Row(Modifier.fillMaxWidth()) {
                padded(row).forEach { cell ->
                    DshInlineText(
                        cell,
                        style = MdCaption,
                        modifier = Modifier.weight(1f).padding(end = 14.dp, bottom = 4.dp),
                    )
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Inline markdown → AnnotatedString
// ---------------------------------------------------------------------------

private const val LINK_TAG = "dsh-link"

/**
 * SwiftUI interprets inline markup with
 * `AttributedString(markdown:, .inlineOnlyPreservingWhitespace)`; the core
 * parser only splits blocks, so `**bold**`, `*italic*`/`_italic_`,
 * `` `code` ``, `[text](url)` and `~~strike~~`` are applied here. URL taps go
 * through [LocalUriHandler].
 */
@Composable
internal fun DshInlineText(
    text: String,
    modifier: Modifier = Modifier,
    style: TextStyle = MdBody,
) {
    val accent = MaterialTheme.colorScheme.primary
    val codeBackground = DSHColors.secondaryLabel().copy(alpha = 0.16f)
    val annotated = remember(text, accent, codeBackground) {
        buildInlineAnnotated(text, accent, codeBackground)
    }
    val uriHandler = LocalUriHandler.current
    var layoutResult by remember(annotated) { mutableStateOf<TextLayoutResult?>(null) }
    Text(
        text = annotated,
        style = style,
        modifier = modifier.pointerInput(annotated) {
            detectTapGestures { offset ->
                val result = layoutResult ?: return@detectTapGestures
                val hit = result.getOffsetForPosition(offset)
                annotated.getStringAnnotations(LINK_TAG, hit, hit)
                    .firstOrNull()
                    ?.let { annotation ->
                        runCatching { uriHandler.openUri(annotation.item) }
                    }
            }
        },
        onTextLayout = { layoutResult = it },
    )
}

private fun buildInlineAnnotated(
    raw: String,
    linkColor: Color,
    codeBackground: Color,
): AnnotatedString = buildAnnotatedString {
    appendParsedInline(raw, linkColor, codeBackground)
}

/** Recursive scanner; call inside an [AnnotatedString.Builder] scope. */
private fun AnnotatedString.Builder.appendParsedInline(
    s: String,
    linkColor: Color,
    codeBackground: Color,
) {
    val boldStyle = SpanStyle(fontWeight = FontWeight.Bold)
    val italicStyle = SpanStyle(fontStyle = FontStyle.Italic)
    val strikeStyle = SpanStyle(textDecoration = TextDecoration.LineThrough)
    val codeStyle = SpanStyle(fontFamily = FontFamily.Monospace, background = codeBackground)
    val linkStyle = SpanStyle(color = linkColor, textDecoration = TextDecoration.Underline)

    val literal = StringBuilder()
    fun flush() {
        if (literal.isNotEmpty()) {
            append(literal.toString())
            literal.setLength(0)
        }
    }

    var i = 0
    while (i < s.length) {
        val c = s[i]
        // Backslash escapes for punctuation (matches AttributedString behaviour).
        if (c == '\\' && i + 1 < s.length && s[i + 1] in "*_`[]()~#>|") {
            flush()
            append(s[i + 1].toString())
            i += 2
            continue
        }
        if (c == '`') {
            val end = s.indexOf('`', i + 1)
            if (end > i) {
                flush()
                withStyle(codeStyle) {
                    appendParsedInline(s.substring(i + 1, end), linkColor, codeBackground)
                }
                i = end + 1
                continue
            }
        }
        if (c == '*' && s.startsWith("**", i)) {
            val end = s.indexOf("**", i + 2)
            if (end > i + 1) {
                flush()
                withStyle(boldStyle) {
                    appendParsedInline(s.substring(i + 2, end), linkColor, codeBackground)
                }
                i = end + 2
                continue
            }
        }
        if (c == '*' && i + 1 < s.length && s[i + 1] != ' ') {
            val end = s.indexOf('*', i + 1)
            if (end > i) {
                flush()
                withStyle(italicStyle) {
                    appendParsedInline(s.substring(i + 1, end), linkColor, codeBackground)
                }
                i = end + 1
                continue
            }
        }
        if (c == '_' && !literal.endsWithWord() && i + 1 < s.length && s[i + 1] != ' ') {
            val end = s.indexOf('_', i + 1)
            if (end > i) {
                flush()
                withStyle(italicStyle) {
                    appendParsedInline(s.substring(i + 1, end), linkColor, codeBackground)
                }
                i = end + 1
                continue
            }
        }
        if (c == '~' && s.startsWith("~~", i)) {
            val end = s.indexOf("~~", i + 2)
            if (end > i + 1) {
                flush()
                withStyle(strikeStyle) {
                    appendParsedInline(s.substring(i + 2, end), linkColor, codeBackground)
                }
                i = end + 2
                continue
            }
        }
        if (c == '[') {
            val close = matchingBracket(s, i)
            if (close != null && close + 1 < s.length && s[close + 1] == '(') {
                val urlEnd = s.indexOf(')', close + 2)
                if (urlEnd > close) {
                    val label = s.substring(i + 1, close)
                    val url = s.substring(close + 2, urlEnd)
                    flush()
                    pushStringAnnotation(LINK_TAG, url)
                    withStyle(linkStyle) { appendParsedInline(label, linkColor, codeBackground) }
                    pop()
                    i = urlEnd + 1
                    continue
                }
            }
        }
        literal.append(c)
        i += 1
    }
    flush()
}

private fun StringBuilder.endsWithWord(): Boolean {
    val last = lastOrNull() ?: return false
    return last.isLetterOrDigit()
}

/** Index of the `]` matching the `[` at [open], or null when unbalanced. */
private fun matchingBracket(s: String, open: Int): Int? {
    var depth = 0
    var i = open
    while (i < s.length) {
        when (s[i]) {
            '[' -> depth += 1
            ']' -> {
                depth -= 1
                if (depth == 0) return i
            }
        }
        i += 1
    }
    return null
}
