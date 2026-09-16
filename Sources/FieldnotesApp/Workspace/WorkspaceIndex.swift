import Foundation

struct WorkspaceSearchResult: Equatable, Sendable {
    let id: String
    let title: String
}

final class WorkspaceIndex: @unchecked Sendable {
    private let root: URL
    private let maximumFiles: Int
    private struct Record { let url: URL; let title: String; let line: Int? }
    private var records: [String: Record] = [:]

    init(root: URL, maximumFiles: Int = 2_000) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumFiles = min(max(maximumFiles, 1), 10_000)
        rebuild()
    }

    func search(_ query: String, limit: Int = 50, includeContent: Bool = true) -> [WorkspaceSearchResult] {
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return records
            .compactMap { id, record -> WorkspaceSearchResult? in
                guard includeContent || record.line == nil else { return nil }
                let relative = record.title
                guard needle.isEmpty || relative.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) else { return nil }
                return WorkspaceSearchResult(id: id, title: relative)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .prefix(min(max(limit, 0), 100))
            .map { $0 }
    }

    func resolve(id: String) -> URL? {
        guard id.count <= 128, let stored = records[id] else { return nil }
        let canonical = stored.url.resolvingSymlinksInPath().standardizedFileURL
        guard canonical == stored.url, contains(canonical), isRegularMarkdown(canonical) else { return nil }
        return canonical
    }

    func line(id: String) -> Int? { records[id]?.line }

    private func rebuild() {
        records.removeAll(keepingCapacity: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }
        var fileCount = 0
        for case let url as URL in enumerator {
            if fileCount >= maximumFiles { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, isRegularMarkdown(url) else { continue }
            fileCount += 1
            let canonical = url.standardizedFileURL
            let title = relativePath(canonical)
            records[UUID().uuidString] = Record(url: canonical, title: title, line: nil)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var fenced = false, frontmatter = false, tags = false, contentCount = 0
            for (offset, raw) in source.components(separatedBy: "\n").enumerated() {
                if contentCount >= 200 { break }
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if offset == 0 && line == "---" { frontmatter = true; continue }
                if frontmatter && line == "---" { frontmatter = false; tags = false; continue }
                var labels: [String] = []
                if frontmatter {
                    if line.hasPrefix("tags:") {
                        tags = true
                        labels += line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " []")).components(separatedBy: ",")
                    } else if tags && line.hasPrefix("- ") { labels.append(String(line.dropFirst(2))) }
                    else if !line.isEmpty { tags = false }
                } else {
                    if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
                    if fenced { continue }
                    if line.hasPrefix("## ") { labels.append(String(line.dropFirst(3))) }
                    if line.hasPrefix("### ") { labels.append(String(line.dropFirst(4))) }
                    let pattern = #"(?<!!)\[([^\]]+)\]\([^\)]+\)"#
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        for match in regex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                            if let range = Range(match.range(at: 1), in: line) { labels.append(String(line[range])) }
                        }
                    }
                }
                for label in labels {
                    let clean = label.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    guard !clean.isEmpty else { continue }
                    records[UUID().uuidString] = Record(url: canonical, title: title + " — " + clean, line: offset + 1)
                    contentCount += 1
                }
            }
        }
    }

    private func isRegularMarkdown(_ url: URL) -> Bool {
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func contains(_ candidate: URL) -> Bool {
        let rootParts = root.pathComponents
        let candidateParts = candidate.pathComponents
        return candidateParts.count > rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    private func relativePath(_ url: URL) -> String {
        url.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }
}
