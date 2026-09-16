import Foundation

/// Bounded native search extraction; destinations refer to source lines, never label lookups.
enum MarkdownSearchStructure {
    struct Entry: Sendable { let title: String; let line: Int }
    private struct SourceLine { let text: String; let number: Int }

    static func entries(_ source: String, limit: Int) -> [Entry] {
        guard limit > 0 else { return [] }
        let lines = source.components(separatedBy: "\n")
        var body: [SourceLine] = [], result: [Entry] = [], definitions = Set<String>()
        var frontmatter = false, tags = false
        var fence: (character: Character, length: Int)?
        func append(_ title: String, line: Int) {
            guard result.count < limit else { return }
            let clean = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !clean.isEmpty { result.append(Entry(title: clean, line: line)) }
        }
        for (offset, raw) in lines.enumerated() {
            if Task.isCancelled { return [] }
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if offset == 0 && line == "---" { frontmatter = true; continue }
            if frontmatter {
                if line == "---" { frontmatter = false; tags = false; continue }
                if line.hasPrefix("tags:") {
                    tags = true
                    for label in line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []")).split(separator: ",") {
                        if result.count >= limit { break }
                        append(String(label), line: offset + 1)
                    }
                } else if tags && line.hasPrefix("- ") { append(String(line.dropFirst(2)), line: offset + 1) }
                else if !line.isEmpty { tags = false }
                continue
            }
            if raw.hasPrefix("    ") || raw.hasPrefix("\t") { body.append(SourceLine(text: "", number: offset + 1)); continue }
            if let active = fence {
                let run = line.prefix(while: { $0 == active.character })
                if run.count >= active.length && line.dropFirst(run.count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                continue
            }
            if let first = line.first, first == "`" || first == "~" {
                let length = line.prefix(while: { $0 == first }).count
                if length >= 3 { fence = (first, length); body.append(SourceLine(text: "", number: offset + 1)); continue }
            }
            if let definition = captures(#"^\s{0,3}\[([^\]]+)\]:\s*\S"#, in: raw).first?.first {
                definitions.insert(identifier(definition))
                body.append(SourceLine(text: "", number: offset + 1))
                continue
            }
            body.append(SourceLine(text: raw, number: offset + 1))
        }
        var paragraph: [SourceLine] = []
        for item in body {
            if result.count >= limit || Task.isCancelled { break }
            let line = item.text.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { paragraph.removeAll(keepingCapacity: true); continue }
            if !paragraph.isEmpty && line.allSatisfy({ $0 == "-" }) {
                append(label(paragraph.map(\.text).joined(separator: " ")), line: paragraph[0].number)
                paragraph.removeAll(keepingCapacity: true)
                continue
            }
            let heading = captures(#"^ {0,3}(#{2,3})(?:\s+|$)(.*?)(?:\s+#+\s*)?$"#, in: item.text).first
            if let heading, heading.count == 2 {
                append(label(heading[1]), line: item.number)
                paragraph.removeAll(keepingCapacity: true)
            } else if line.hasPrefix("#") || line.allSatisfy({ $0 == "=" }) {
                paragraph.removeAll(keepingCapacity: true)
            } else { paragraph.append(item) }
            let searchable = item.text.replacingOccurrences(of: #"(`+).*?\1"#, with: "", options: .regularExpression)
            for capture in captures(#"(?<!!)\[([^\]]+)\]\([^\)]+\)"#, in: searchable) {
                if result.count >= limit { break }
                if let title = capture.first { append(label(title), line: item.number) }
            }
            for capture in captures(#"(?<!!)\[([^\]]+)\](?:\[([^\]]*)\])?(?![\[(])"#, in: searchable) {
                if result.count >= limit { break }
                guard let title = capture.first else { continue }
                let reference = capture.count > 1 && !capture[1].isEmpty ? capture[1] : title
                if definitions.contains(identifier(reference)) { append(label(title), line: item.number) }
            }
        }
        return result.sorted { $0.line < $1.line }
    }

    private static func identifier(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func label(_ value: String) -> String {
        value.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
    }

    private static func captures(_ pattern: String, in source: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
            (1..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: source).map { String(source[$0]) } ?? ""
            }
        }
    }
}
