import Foundation

struct DSHToolDiff: Codable, Equatable {
    let path: String
    let oldText: String?
    let newText: String
}
struct DSHToolSearch: Codable, Equatable {
    struct Match: Codable, Equatable { let lineNumber: Int; let line: String }
    struct File: Codable, Equatable { let path: String; let matches: [Match] }
    let shape: String
    let files: [File]?
    let paths: [String]?
    let truncated: Bool
    let total: Int
}
struct DSHToolRead: Codable, Equatable {
    struct Line: Codable, Equatable { let number: Int; let text: String }
    let path: String
    let offset: Int
    let lines: [Line]
    let totalLines: Int
    let lang: String?
}
struct DSHToolWebSearch: Codable, Equatable {
    struct Source: Codable, Equatable { let url: String; let title: String?; let snippet: String?; let publishedAt: String? }
    let sources: [Source]
    let answer: String?
    let truncated: Bool
}
struct DSHToolWebFetch: Codable, Equatable { let url: String; let statusCode: Int; let truncated: Bool }

enum DSHToolResult: Equatable {
    case diff([DSHToolDiff]), search(DSHToolSearch), read(DSHToolRead)
    case webSearch(DSHToolWebSearch), webFetch(DSHToolWebFetch)
    case terminal(output: String, exitCode: Int?, signal: String?)

    static func parse(_ tool: DSHToolActivity) -> Self? {
        // Failed outcomes must retain their diagnostic, never render a stale
        // success projection. Shell non-zero exits are native successful results.
        guard ["succeeded", "completed", "complete", "success"].contains(tool.status) else { return nil }
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            guard let meta = tool.resultMeta, let data = try? JSONEncoder().encode(meta) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        switch tool.name {
        case "write", "edit":
            struct Meta: Decodable { let diffs: [DSHToolDiff] }
            guard let meta = decode(Meta.self), !meta.diffs.isEmpty else { return nil }
            return .diff(meta.diffs)
        case "grep", "glob":
            guard let meta = decode(DSHToolSearch.self), meta.total >= 0 else { return nil }
            if meta.shape == "paths", let paths = meta.paths, meta.total >= paths.count { return .search(meta) }
            if meta.shape == "matches", let files = meta.files,
               files.allSatisfy({ $0.matches.allSatisfy { $0.lineNumber > 0 } }),
               meta.total >= files.reduce(0, { $0 + $1.matches.count }) { return .search(meta) }
            return nil
        case "read":
            guard let meta = decode(DSHToolRead.self), meta.offset >= 1, meta.totalLines >= 0 else { return nil }
            var previous = meta.offset - 1
            for line in meta.lines {
                guard line.number > previous, line.number <= meta.totalLines else { return nil }
                previous = line.number
            }
            return .read(meta)
        case "web_search": return decode(DSHToolWebSearch.self).map(Self.webSearch)
        case "web_fetch": return decode(DSHToolWebFetch.self).map(Self.webFetch)
        case "bash", "pwsh":
            guard let text = tool.detail else { return nil }
            // Same anchored marker contract as dsh-shell/parseExitStatus.
            for (pattern, signal) in [("\\n\\[killed by signal: ([^\\]\\n]+)\\]$", true), ("\\n\\[exit code: (\\d+)\\]$", false)] {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let range = Range(match.range(at: 1), in: text), let marker = Range(match.range, in: text) else { continue }
                return .terminal(output: String(text[..<marker.lowerBound]), exitCode: signal ? nil : Int(text[range]), signal: signal ? String(text[range]) : nil)
            }
            return .terminal(output: text, exitCode: 0, signal: nil)
        default: return nil
        }
    }

    static func webURL(_ text: String) -> URL? {
        guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        return url
    }
}

struct DSHToolDiffLine: Identifiable, Equatable {
    let id: Int
    let kind: String
    let text: String
    static func lines(_ diff: DSHToolDiff) -> [Self] {
        let before = diff.oldText.flatMap { $0.isEmpty ? nil : $0.components(separatedBy: "\n") } ?? []
        let after = diff.newText.isEmpty ? [] : diff.newText.components(separatedBy: "\n")
        var rows: [(String, String)] = []
        // Large full-file writes avoid a quadratic edit search. Both images
        // remain available, explicitly marked as removed/added.
        if before.count + after.count > 2_000 {
            rows = before.map { ("−", $0) } + after.map { ("+", $0) }
        } else {
            let delta = after.difference(from: before)
            var removals = Set<Int>(), insertions = Set<Int>()
            for change in delta {
                switch change { case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset) }
            }
            var old = 0, new = 0
            while old < before.count || new < after.count {
                if old < before.count, removals.contains(old) { rows.append(("−", before[old])); old += 1 }
                else if new < after.count, insertions.contains(new) { rows.append(("+", after[new])); new += 1 }
                else if new < after.count { rows.append((" ", after[new])); old += 1; new += 1 }
                else { break }
            }
        }
        return rows.enumerated().map { Self(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }
}

extension DSHToolActivity {
    /// Native subcalls remain under their parent. Orphans, malformed cycles
    /// and excessively deep branches stay visible as standalone rows.
    static func nested(_ tools: [Self]) -> [Self] {
        let byID = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parents: [String: String] = [:]
        for tool in tools {
            guard let parent = tool.parentCallId, let root = tool.rootCallId, root != tool.id,
                  let rootTool = byID[root], rootTool.parentCallId == nil else { continue }
            var cursor: String? = parent, visited: Set<String> = [tool.id], valid = false
            while let id = cursor, let entry = byID[id], visited.count < 24, visited.insert(id).inserted {
                if id == root { valid = true; break }
                cursor = entry.parentCallId
            }
            if valid { parents[tool.id] = parent }
        }
        let childrenByParent = Dictionary(grouping: tools.filter { parents[$0.id] != nil }, by: { parents[$0.id]! })
        func build(_ tool: Self) -> Self {
            var result = tool
            let children = childrenByParent[tool.id, default: []].map(build)
            result.children = children.isEmpty ? nil : children
            return result
        }
        return tools.filter { parents[$0.id] == nil }.map(build)
    }
}
