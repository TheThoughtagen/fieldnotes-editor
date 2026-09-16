import Foundation

public enum PresentationMode: String, Codable, CaseIterable, Sendable {
    case focus, source, preview
}

public enum LocalAssetPolicy: String, Codable, Sendable {
    case workspace
    case documentDirectory = "document-directory"
}

public enum SchemaResolution: Equatable, Sendable {
    case none
    case loaded(url: URL, data: Data)
    case diagnostic(String)
}

public struct WorkspaceContext: Equatable, Sendable {
    public let workspace: URL
    public let document: URL?
    public let schema: SchemaResolution
    public let localAssetPolicy: LocalAssetPolicy
    public let diagnostics: [String]

    public init(workspace: URL, document: URL?, schema: SchemaResolution, localAssetPolicy: LocalAssetPolicy, diagnostics: [String] = []) {
        self.workspace = workspace
        self.document = document
        self.schema = schema
        self.localAssetPolicy = localAssetPolicy
        self.diagnostics = diagnostics
    }
}

public enum WorkspaceError: Error, Equatable, CustomStringConvertible {
    case missingTarget(String)
    case unsupportedTarget(String)
    case invalidConfig(String)

    public var description: String {
        switch self {
        case .missingTarget(let path): "target does not exist: \(path)"
        case .unsupportedTarget(let path): "target is not a regular file or directory: \(path)"
        case .invalidConfig(let message): "invalid .fieldnotes.json: \(message)"
        }
    }
}

public struct WorkspaceResolver: Sendable {
    public init() {}

    public func resolve(input: URL, explicitSchema: URL? = nil, workspaceRoot: URL? = nil) throws -> WorkspaceContext {
        let canonical = input.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
            throw WorkspaceError.missingTarget(canonical.path)
        }
        guard isRegularFile(canonical) || isDirectory.boolValue else {
            throw WorkspaceError.unsupportedTarget(canonical.path)
        }
        let document = isDirectory.boolValue ? nil : canonical
        let start = isDirectory.boolValue ? canonical : canonical.deletingLastPathComponent()
        let workspace = workspaceRoot?.resolvingSymlinksInPath().standardizedFileURL ?? (isDirectory.boolValue ? canonical : nearestWorkspace(from: start))
        guard contains(canonical, in: workspace) else { throw WorkspaceError.unsupportedTarget(canonical.path) }
        let configURL = discover(".fieldnotes.json", from: start, through: workspace)
        let config: FieldnotesConfig?
        do { config = try configURL.map { try readConfig(at: $0) } }
        catch {
            return WorkspaceContext(workspace: workspace, document: document,
                                    schema: explicitSchema.map { loadSchema($0) } ?? .diagnostic(String(describing: error)),
                                    localAssetPolicy: .workspace, diagnostics: explicitSchema == nil ? [] : [String(describing: error)])
        }
        let policy = config?.localAssetPolicy ?? .workspace
        let schema: SchemaResolution
        if let explicitSchema {
            schema = loadSchema(explicitSchema.standardizedFileURL)
        } else if let relative = config?.frontmatterSchema, let configURL {
            let candidate = configURL.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL
            schema = contains(candidate, in: workspace)
                ? loadSchema(candidate)
                : .diagnostic("invalid .fieldnotes.json: frontmatterSchema escapes the workspace")
        } else if let discovered = discover("frontmatter.schema.json", from: start, through: workspace) {
            schema = loadSchema(discovered)
        } else { schema = .none }
        return WorkspaceContext(workspace: workspace, document: document, schema: schema, localAssetPolicy: policy)
    }

    private func nearestWorkspace(from start: URL) -> URL {
        var cursor = start
        while true {
            if isMarker(cursor.appendingPathComponent(".fieldnotes.json"))
                || isMarker(cursor.appendingPathComponent(".git")) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { return start }
            cursor = parent
        }
    }

    private func isMarker(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
              values.isSymbolicLink != true
        else { return false }
        return values.isRegularFile == true || values.isDirectory == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidateParts = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidateParts.count >= rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    private func loadSchema(_ url: URL) -> SchemaResolution {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension.lowercased() == "json", isRegularFile(url), canonical == url.standardizedFileURL else {
            return .diagnostic("Schema is unavailable or unsafe: \(url.path)")
        }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else {
                return .diagnostic("Schema is too large: \(url.path)")
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= 1_048_576,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .diagnostic("Schema is not a bounded JSON object: \(url.path)") }
            _ = object
            return .loaded(url: canonical, data: data)
        } catch {
            return .diagnostic("Schema could not be read: \(url.path)")
        }
    }

    private func discover(_ name: String, from start: URL, through root: URL) -> URL? {
        var cursor = start
        while contains(cursor, in: root) {
            let candidate = cursor.appendingPathComponent(name)
            if isMarker(candidate) { return candidate }
            if cursor == root { break }
            cursor = cursor.deletingLastPathComponent()
        }
        return nil
    }

    private func readConfig(at url: URL) throws -> FieldnotesConfig {
        guard isRegularFile(url),
              let data = try? Data(contentsOf: url), data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WorkspaceError.invalidConfig("must be a bounded JSON object") }
        let allowed: Set<String> = ["frontmatterSchema", "localAssetPolicy"]
        if let extra = Set(object.keys).subtracting(allowed).sorted().first {
            throw WorkspaceError.invalidConfig("unexpected key \(extra)")
        }
        let schema: String?
        if let raw = object["frontmatterSchema"] {
            guard let value = raw as? String, !value.isEmpty, !(value as NSString).isAbsolutePath else {
                throw WorkspaceError.invalidConfig("frontmatterSchema must be a relative path")
            }
            schema = value
        } else { schema = nil }
        let policy: LocalAssetPolicy
        if let raw = object["localAssetPolicy"] {
            guard let value = raw as? String, let decoded = LocalAssetPolicy(rawValue: value) else {
                throw WorkspaceError.invalidConfig("invalid localAssetPolicy")
            }
            policy = decoded
        } else { policy = .workspace }
        return FieldnotesConfig(frontmatterSchema: schema, localAssetPolicy: policy)
    }
}

private struct FieldnotesConfig {
    let frontmatterSchema: String?
    let localAssetPolicy: LocalAssetPolicy
}
