import Foundation

public enum OpenRequestError: Error, Equatable, CustomStringConvertible {
    case malformed(String)

    public var description: String {
        switch self { case .malformed(let message): "invalid FIELDNOTES open URL: \(message)" }
    }
}

public struct OpenRequest: Equatable, Sendable {
    public let target: URL
    public let schema: URL?
    public let mode: PresentationMode?
    public let line: Int?
    public let column: Int?

    public init(target: URL, schema: URL? = nil, mode: PresentationMode? = nil, line: Int? = nil, column: Int? = nil) {
        self.target = target.standardizedFileURL.resolvingSymlinksInPath()
        self.schema = schema?.standardizedFileURL.resolvingSymlinksInPath()
        self.mode = mode
        self.line = line
        self.column = column
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == AppIdentity.urlScheme, components.host == "open",
              components.path.isEmpty, components.fragment == nil,
              components.user == nil, components.password == nil, components.port == nil
        else { throw OpenRequestError.malformed("scheme, host, or structure") }
        let allowed: Set<String> = ["path", "schema", "mode", "line", "column"]
        let items = components.queryItems ?? []
        guard items.count <= allowed.count, Set(items.map(\.name)).isSubset(of: allowed),
              Set(items.map(\.name)).count == items.count
        else { throw OpenRequestError.malformed("duplicate or unknown query") }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let path = fields["path"], path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 16_384 else {
            throw OpenRequestError.malformed("path")
        }
        if let schema = fields["schema"] {
            guard schema.hasPrefix("/"), !schema.contains("\0"), schema.utf8.count <= 16_384 else { throw OpenRequestError.malformed("schema") }
        }
        let mode: PresentationMode?
        if let raw = fields["mode"] {
            guard let value = PresentationMode(rawValue: raw) else { throw OpenRequestError.malformed("mode") }
            mode = value
        } else { mode = nil }
        let line = try Self.positive(fields["line"], name: "line")
        let column = try Self.positive(fields["column"], name: "column")
        guard column == nil || line != nil else { throw OpenRequestError.malformed("column requires line") }
        self.init(
            target: URL(fileURLWithPath: path),
            schema: fields["schema"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) },
            mode: mode,
            line: line,
            column: column
        )
    }

    public func url() throws -> URL {
        guard target.isFileURL, column == nil || line != nil,
              line.map({ $0 > 0 }) ?? true, column.map({ $0 > 0 }) ?? true
        else { throw OpenRequestError.malformed("request fields") }
        var components = URLComponents()
        components.scheme = AppIdentity.urlScheme
        components.host = "open"
        var items = [URLQueryItem(name: "path", value: target.path)]
        if let schema { items.append(URLQueryItem(name: "schema", value: schema.path)) }
        if let mode { items.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let column { items.append(URLQueryItem(name: "column", value: String(column))) }
        components.queryItems = items
        guard let result = components.url else { throw OpenRequestError.malformed("encoding") }
        return result
    }

    private static func positive(_ raw: String?, name: String) throws -> Int? {
        guard let raw else { return nil }
        guard raw.count <= 9, let value = Int(raw), value > 0 else { throw OpenRequestError.malformed(name) }
        return value
    }
}

public enum CLIError: Error, Equatable, CustomStringConvertible {
    case usage(String)
    public var description: String { switch self { case .usage(let value): value } }
    public var exitCode: Int32 { 64 }
}

public enum CLIArguments: Equatable, Sendable {
    case help
    case open(OpenRequest)

    public var request: OpenRequest {
        guard case .open(let request) = self else { preconditionFailure("help has no request") }
        return request
    }

    public static let helpText = """
    usage: fieldnotes [--schema FILE] [--mode focus|source|preview] [--line N [--column N]] PATH
           fieldnotes --help
    """

    public static func parse(_ arguments: [String], currentDirectory: URL) throws -> CLIArguments {
        if arguments == ["--help"] || arguments == ["-h"] { return .help }
        var schema: URL?, mode: PresentationMode?, line: Int?, column: Int?, target: URL?
        var index = 0
        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else { throw CLIError.usage("missing value for \(flag)") }
            index += 1
            return arguments[index]
        }
        while index < arguments.count {
            let item = arguments[index]
            switch item {
            case "--schema": schema = fileURL(try value(after: item), cwd: currentDirectory)
            case "--mode":
                let raw = try value(after: item)
                guard let parsed = PresentationMode(rawValue: raw) else { throw CLIError.usage("invalid mode: \(raw)") }
                mode = parsed
            case "--line": line = try positive(try value(after: item), flag: item)
            case "--column": column = try positive(try value(after: item), flag: item)
            default:
                guard !item.hasPrefix("-"), target == nil else { throw CLIError.usage("unexpected argument: \(item)") }
                target = fileURL(item, cwd: currentDirectory)
            }
            index += 1
        }
        guard let target else { throw CLIError.usage("missing PATH") }
        guard column == nil || line != nil else { throw CLIError.usage("--column requires --line") }
        return .open(OpenRequest(target: target, schema: schema, mode: mode, line: line, column: column))
    }

    private static func fileURL(_ path: String, cwd: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
    }

    private static func positive(_ raw: String, flag: String) throws -> Int {
        guard raw.count <= 9, let result = Int(raw), result > 0 else { throw CLIError.usage("invalid value for \(flag)") }
        return result
    }
}

public enum CLIApplicationLocation {
    public static func bundledApp(for executable: URL) -> URL? {
        let binary = executable.resolvingSymlinksInPath().standardizedFileURL
        let macOS = binary.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents", app.pathExtension == "app" else { return nil }
        return app
    }
}
