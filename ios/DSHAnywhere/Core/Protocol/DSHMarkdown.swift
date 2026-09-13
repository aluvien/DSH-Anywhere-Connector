import Foundation

/// A block of assistant markdown, already classified.
///
/// `AttributedString(markdown:)` interprets only inline syntax by default, so
/// headings, fenced code, lists and tables came out as their literal markers.
/// Block structure has to be recognised first, then rendered.
public struct DSHMarkdownBlock: Identifiable, Equatable, Sendable {
    public let id: Int
    public let kind: Kind

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(language: String?, body: String)
        case bullets([String])
        case numbers([String])
        case quote(String)
        case table(header: [String], rows: [[String]])
        case divider
    }

    /// Text this block contributes to a copy/plain-text rendering.
    public var plainText: String {
        switch kind {
        case .heading(_, let text): return text
        case .paragraph(let text): return text
        case .code(_, let body): return body
        case .bullets(let items): return items.map { "• \($0)" }.joined(separator: "\n")
        case .numbers(let items): return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        case .quote(let text): return text
        case .table(let header, let rows):
            return ([header] + rows).map { $0.joined(separator: " | ") }.joined(separator: "\n")
        case .divider: return "---"
        }
    }
}

/// Line-oriented markdown block parser.
///
/// Deliberately not full CommonMark: it covers what assistant answers actually
/// contain — headings, fenced code, lists, tables, quotes, rules — and leaves
/// inline styling (bold, code spans, links) to `AttributedString`.
public enum DSHMarkdown {
    public static func blocks(from text: String) -> [DSHMarkdownBlock] {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = source.components(separatedBy: "\n")

        var kinds: [DSHMarkdownBlock.Kind] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { kinds.append(.paragraph(joined)) }
            paragraph = []
        }

        while index < lines.count {
            let raw = lines[index]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                var body: [String] = []
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                // An unterminated fence still ends the block: swallowing the
                // rest of the message as code would hide everything after it.
                if index < lines.count { index += 1 }
                kinds.append(.code(language: language.isEmpty ? nil : language,
                                   body: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = headingKind(trimmed) {
                flushParagraph()
                kinds.append(heading)
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                kinds.append(.divider)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                        .trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                kinds.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if isTableHeader(lines: lines, at: index) {
                flushParagraph()
                let header = tableCells(lines[index])
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(tableCells(lines[index]))
                    index += 1
                }
                kinds.append(.table(header: header, rows: rows))
                continue
            }

            if let item = listItem(trimmed, marker: .bullet) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = listItem(lines[index].trimmingCharacters(in: .whitespaces), marker: .bullet) {
                    items.append(next)
                    index += 1
                }
                kinds.append(.bullets(items))
                continue
            }

            if let item = listItem(trimmed, marker: .number) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = listItem(lines[index].trimmingCharacters(in: .whitespaces), marker: .number) {
                    items.append(next)
                    index += 1
                }
                kinds.append(.numbers(items))
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }

        flushParagraph()
        return kinds.enumerated().map { DSHMarkdownBlock(id: $0.offset, kind: $0.element) }
    }

    // MARK: - Recognition

    private static func headingKind(_ line: String) -> DSHMarkdownBlock.Kind? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        // "#######" or "#hashtag" are not headings.
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: level, text: text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private enum ListMarker { case bullet, number }

    private static func listItem(_ line: String, marker: ListMarker) -> String? {
        switch marker {
        case .bullet:
            for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
                let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
            return nil
        case .number:
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    private static func isTableHeader(lines: [String], at index: Int) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return false }
        guard index + 1 < lines.count else { return false }
        let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
        guard separator.hasPrefix("|"), separator.hasSuffix("|") else { return false }
        // Every cell of the separator row must be dashes, optionally `:---:`.
        let cells = tableCells(separator)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.replacingOccurrences(of: ":", with: "")
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
