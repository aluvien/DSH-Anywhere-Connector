package com.dshanywhere.core.protocol

/**
 * A block of assistant markdown, already classified. Port of
 * ios/DSHAnywhere/Core/Protocol/DSHMarkdown.swift.
 *
 * Inline styling (bold, code spans, links) is applied later at render time;
 * block structure has to be recognised first.
 */
data class DSHMarkdownBlock(
    val id: Int,
    val kind: Kind,
) {
    sealed interface Kind {
        data class Heading(val level: Int, val text: String) : Kind
        data class Paragraph(val text: String) : Kind
        data class Code(val language: String?, val body: String) : Kind
        data class Bullets(val items: List<String>) : Kind
        data class Numbers(val items: List<String>) : Kind
        data class Quote(val text: String) : Kind
        data class Table(val header: List<String>, val rows: List<List<String>>) : Kind
        data object Divider : Kind
    }

    /** Text this block contributes to a copy/plain-text rendering. */
    val plainText: String
        get() = when (val k = kind) {
            is Kind.Heading -> k.text
            is Kind.Paragraph -> k.text
            is Kind.Code -> k.body
            is Kind.Bullets -> k.items.joinToString("\n") { "• $it" }
            is Kind.Numbers -> k.items.mapIndexed { i, s -> "${i + 1}. $s" }.joinToString("\n")
            is Kind.Quote -> k.text
            is Kind.Table -> (listOf(k.header) + k.rows).joinToString("\n") { it.joinToString(" | ") }
            Kind.Divider -> "---"
        }
}

/**
 * Line-oriented markdown block parser.
 *
 * Deliberately not full CommonMark: it covers what assistant answers actually
 * contain — headings, fenced code, lists, tables, quotes, rules — and leaves
 * inline styling to the renderer.
 */
object DSHMarkdown {
    fun blocks(text: String): List<DSHMarkdownBlock> {
        val source = text.replace("\r\n", "\n")
        val lines = source.split("\n")

        val kinds = mutableListOf<DSHMarkdownBlock.Kind>()
        var paragraph = mutableListOf<String>()
        var index = 0

        fun flushParagraph() {
            val joined = paragraph.joinToString("\n").trim()
            if (joined.isNotEmpty()) kinds.add(DSHMarkdownBlock.Kind.Paragraph(joined))
            paragraph = mutableListOf()
        }

        while (index < lines.size) {
            val raw = lines[index]
            val trimmed = raw.trim()

            if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
                flushParagraph()
                val fence = trimmed.take(3)
                val language = trimmed.drop(3).trim()
                index += 1
                val body = mutableListOf<String>()
                while (index < lines.size &&
                    !lines[index].trim().startsWith(fence)
                ) {
                    body.add(lines[index])
                    index += 1
                }
                // An unterminated fence still ends the block: swallowing the
                // rest of the message as code would hide everything after it.
                if (index < lines.size) index += 1
                kinds.add(DSHMarkdownBlock.Kind.Code(
                    language = language.ifEmpty { null },
                    body = body.joinToString("\n"),
                ))
                continue
            }

            if (trimmed.isEmpty()) {
                flushParagraph()
                index += 1
                continue
            }

            val heading = headingKind(trimmed)
            if (heading != null) {
                flushParagraph()
                kinds.add(heading)
                index += 1
                continue
            }

            if (isDivider(trimmed)) {
                flushParagraph()
                kinds.add(DSHMarkdownBlock.Kind.Divider)
                index += 1
                continue
            }

            if (trimmed.startsWith(">")) {
                flushParagraph()
                val quoted = mutableListOf<String>()
                while (index < lines.size && lines[index].trim().startsWith(">")) {
                    quoted.add(lines[index].trim().drop(1).trim())
                    index += 1
                }
                kinds.add(DSHMarkdownBlock.Kind.Quote(quoted.joinToString("\n")))
                continue
            }

            if (isTableHeader(lines, index)) {
                flushParagraph()
                val header = tableCells(lines[index])
                index += 2
                val rows = mutableListOf<List<String>>()
                while (index < lines.size && lines[index].trim().startsWith("|")) {
                    rows.add(tableCells(lines[index]))
                    index += 1
                }
                kinds.add(DSHMarkdownBlock.Kind.Table(header, rows))
                continue
            }

            val bulletItem = listItem(trimmed, bullet = true)
            if (bulletItem != null) {
                flushParagraph()
                val items = mutableListOf(bulletItem)
                index += 1
                while (index < lines.size) {
                    val next = listItem(lines[index].trim(), bullet = true) ?: break
                    items.add(next)
                    index += 1
                }
                kinds.add(DSHMarkdownBlock.Kind.Bullets(items))
                continue
            }

            val numberItem = listItem(trimmed, bullet = false)
            if (numberItem != null) {
                flushParagraph()
                val items = mutableListOf(numberItem)
                index += 1
                while (index < lines.size) {
                    val next = listItem(lines[index].trim(), bullet = false) ?: break
                    items.add(next)
                    index += 1
                }
                kinds.add(DSHMarkdownBlock.Kind.Numbers(items))
                continue
            }

            paragraph.add(trimmed)
            index += 1
        }

        flushParagraph()
        return kinds.mapIndexed { i, kind -> DSHMarkdownBlock(id = i, kind = kind) }
    }

    // --- Recognition ---

    private fun headingKind(line: String): DSHMarkdownBlock.Kind? {
        if (!line.startsWith("#")) return null
        val hashes = line.takeWhile { it == '#' }
        val level = hashes.length
        if (level > 6) return null
        val rest = line.drop(level)
        // "#######" or "#hashtag" are not headings.
        val first = rest.firstOrNull()
        if (first != ' ' && first != null) return null
        if (rest.isNotEmpty() && first == null) return null
        val text = rest.trim()
        if (text.isEmpty()) return null
        return DSHMarkdownBlock.Kind.Heading(level, text)
    }

    private fun isDivider(line: String): Boolean {
        val stripped = line.replace(" ", "")
        if (stripped.length < 3) return false
        return stripped.all { it == '-' } || stripped.all { it == '*' } || stripped.all { it == '_' }
    }

    private fun listItem(line: String, bullet: Boolean): String? {
        return if (bullet) {
            for (prefix in listOf("- ", "* ", "+ ")) {
                if (line.startsWith(prefix)) {
                    val text = line.drop(prefix.length).trim()
                    return text.ifEmpty { null }
                }
            }
            null
        } else {
            val digits = line.takeWhile { it.isDigit() }
            if (digits.isEmpty()) return null
            val rest = line.drop(digits.length)
            if (!(rest.startsWith(". ") || rest.startsWith(") "))) return null
            val text = rest.drop(2).trim()
            text.ifEmpty { null }
        }
    }

    private fun isTableHeader(lines: List<String>, index: Int): Boolean {
        val line = lines[index].trim()
        if (!(line.startsWith("|") && line.endsWith("|"))) return false
        if (index + 1 >= lines.size) return false
        val separator = lines[index + 1].trim()
        if (!(separator.startsWith("|") && separator.endsWith("|"))) return false
        // Every cell of the separator row must be dashes, optionally `:---:`.
        val cells = tableCells(separator)
        if (cells.isEmpty()) return false
        return cells.all { cell ->
            val stripped = cell.replace(":", "")
            stripped.isNotEmpty() && stripped.all { it == '-' }
        }
    }

    private fun tableCells(line: String): List<String> {
        var body = line.trim()
        if (body.startsWith("|")) body = body.drop(1)
        if (body.endsWith("|")) body = body.dropLast(1)
        return body.split("|").map { it.trim() }
    }
}
