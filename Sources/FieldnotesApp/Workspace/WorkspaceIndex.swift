import Foundation
import FieldnotesCore

struct WorkspaceSearchResult: Equatable, Sendable {
    let id: String
    let title: String
}

struct WorkspaceIndex: Sendable {
    private let root: URL
    private let maximumFiles: Int
    private let maximumEntries: Int
    private struct Record: Sendable { let url: URL; let title: String; let line: Int? }
    private var records: [String: Record] = [:]

    init(root: URL, maximumFiles: Int = 2_000, maximumEntries: Int = 20_000) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.maximumFiles = min(max(maximumFiles, 1), 10_000)
        self.maximumEntries = min(max(maximumEntries, 0), 100_000)
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

    private mutating func rebuild() {
        records.removeAll(keepingCapacity: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }
        var fileCount = 0, visitedEntries = 0
        while visitedEntries < maximumEntries, fileCount < maximumFiles, !Task.isCancelled,
              let url = enumerator.nextObject() as? URL {
            visitedEntries += 1
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true,
                  values.isHidden != true, !url.lastPathComponent.hasPrefix(".") else {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, isRegularMarkdown(url) else { continue }
            fileCount += 1
            let canonical = url.standardizedFileURL
            guard contains(canonical), canonical.resolvingSymlinksInPath() == canonical else { continue }
            let title = relativePath(canonical)
            records[UUID().uuidString] = Record(url: canonical, title: title, line: nil)
            guard let data = try? BoundedFileReader.read(url, maximumBytes: 262_144),
                  let source = String(data: data, encoding: .utf8) else { continue }
            for entry in MarkdownSearchStructure.entries(source, limit: 200) {
                if Task.isCancelled { return }
                records[UUID().uuidString] = Record(url: canonical, title: title + " — " + entry.title, line: entry.line)
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
