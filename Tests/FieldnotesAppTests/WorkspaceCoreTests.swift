import Foundation
import Testing
@testable import FieldnotesCore

@Suite("Workspace and launch core", .serialized)
struct WorkspaceCoreTests {
    @Test("nearest real marker wins and file markers work")
    func nearestMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appendingPathComponent("outer")
        let inner = outer.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data().write(to: outer.appendingPathComponent(".git"))
        try Data("{}".utf8).write(to: inner.appendingPathComponent(".fieldnotes.json"))
        let document = inner.appendingPathComponent("note.md")
        try Data("# Note".utf8).write(to: document)

        let result = try WorkspaceResolver().resolve(input: document)
        #expect(result.workspace == inner.resolvingSymlinksInPath())
        #expect(result.document == document.resolvingSymlinksInPath())
    }

    @Test("symlink markers are ignored and folder input remains exact")
    func symlinkMarkerAndFolder() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let child = workspace.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data().write(to: workspace.appendingPathComponent(".git"))
        try FileManager.default.createSymbolicLink(
            at: child.appendingPathComponent(".fieldnotes.json"),
            withDestinationURL: workspace.appendingPathComponent(".git")
        )

        let result = try WorkspaceResolver().resolve(input: child)
        #expect(result.workspace == child.resolvingSymlinksInPath())
        #expect(result.document == nil)
    }

    @Test("config and schema use strict precedence without fallback")
    func strictSchemaPrecedence() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documentDirectory = root.appendingPathComponent("posts")
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appendingPathComponent("workspace-schema.json"))
        try Data(#"{"frontmatterSchema":"workspace-schema.json","localAssetPolicy":"workspace"}"#.utf8)
            .write(to: root.appendingPathComponent(".fieldnotes.json"))
        let document = documentDirectory.appendingPathComponent("note.md")
        try Data().write(to: document)
        let explicitMissing = documentDirectory.appendingPathComponent("missing.json")

        let context = try WorkspaceResolver().resolve(
            input: document,
            explicitSchema: explicitMissing
        )
        guard case .diagnostic(let message) = context.schema else {
            Issue.record("explicit missing schema must be terminal")
            return
        }
        #expect(message.contains("missing.json"))
    }

    @Test("config rejects extra keys and escaping schema paths")
    func strictConfig() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent(".git"))
        try Data(#"{"frontmatterSchema":"../outside.json","extra":true}"#.utf8)
            .write(to: root.appendingPathComponent(".fieldnotes.json"))
        let document = root.appendingPathComponent("note.md")
        try Data().write(to: document)

        let result = try WorkspaceResolver().resolve(input: document)
        guard case .diagnostic = result.schema else { Issue.record("invalid config must be visible without blocking opening"); return }
        #expect(result.document == document.resolvingSymlinksInPath())
    }

    @Test("open URLs round-trip Unicode and reject ambiguous structure")
    func openRequestURL() throws {
        let request = OpenRequest(
            target: URL(fileURLWithPath: "/tmp/日本語 note.md"),
            schema: URL(fileURLWithPath: "/tmp/schema.json"),
            mode: .preview,
            line: 7,
            column: 3
        )
        let encoded = try request.url()
        #expect(try OpenRequest(url: encoded) == request)

        for source in [
            "fieldnotes://open?path=relative.md",
            "fieldnotes://open?path=/tmp/a.md&schema=",
            "fieldnotes://open?path=/tmp/a.md&schema=relative.json",
            "fieldnotes://open/extra?path=/tmp/a.md",
            "fieldnotes://user@open?path=/tmp/a.md",
            "fieldnotes://open:12?path=/tmp/a.md",
            "fieldnotes://open?path=/tmp/a.md&path=/tmp/b.md",
            "fieldnotes://open?path=/tmp/a.md&column=2",
            "fieldnotes://open?path=/tmp/a.md#fragment",
        ] {
            #expect(throws: OpenRequestError.self) { try OpenRequest(url: try #require(URL(string: source))) }
        }
    }

    @Test("CLI accepts closed flags and emits stable exit classes")
    func cliArguments() throws {
        let parsed = try CLIArguments.parse([
            "--schema", "schema.json", "--mode", "source", "--line", "12", "--column", "4", "note.md",
        ], currentDirectory: URL(fileURLWithPath: "/work"))
        #expect(parsed.request.target.path == "/work/note.md")
        #expect(parsed.request.schema?.path == "/work/schema.json")
        #expect(parsed.request.mode == .source)
        #expect(parsed.request.line == 12)
        #expect(parsed.request.column == 4)

        #expect(try CLIArguments.parse(["--help"], currentDirectory: URL(fileURLWithPath: "/work")) == .help)
        #expect(throws: CLIError.self) {
            try CLIArguments.parse(["--column", "2", "note.md"], currentDirectory: URL(fileURLWithPath: "/work"))
        }
        #expect(throws: CLIError.self) {
            try CLIArguments.parse(["--unknown", "note.md"], currentDirectory: URL(fileURLWithPath: "/work"))
        }
    }

    @Test("schema discovery is nearest and cannot cross a Git marker")
    func discoveredSchema() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: repo.appendingPathComponent(".git"))
        try Data("{}".utf8).write(to: root.appendingPathComponent(".fieldnotes.json"))
        let file = nested.appendingPathComponent("a.md")
        try Data().write(to: file)
        let schema = nested.appendingPathComponent("frontmatter.schema.json")
        try Data("{}".utf8).write(to: schema)
        let result = try WorkspaceResolver().resolve(input: file)
        #expect(result.workspace == repo.resolvingSymlinksInPath())
        #expect(result.schema == .loaded(url: schema.resolvingSymlinksInPath(), data: Data("{}".utf8)))
        try FileManager.default.removeItem(at: schema)
        try Data("{}".utf8).write(to: root.appendingPathComponent("frontmatter.schema.json"))
        #expect(try WorkspaceResolver().resolve(input: file).schema == .none)
    }

    @Test("CLI schema outranks invalid config but its diagnostic remains visible")
    func explicitSchemaWithConfigDiagnostic() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        let schema = root.appendingPathComponent("override.json")
        try Data().write(to: file)
        try Data("{}".utf8).write(to: schema)
        try Data("{broken".utf8).write(to: root.appendingPathComponent(".fieldnotes.json"))
        let result = try WorkspaceResolver().resolve(input: file, explicitSchema: schema)
        #expect(result.schema == .loaded(url: schema.resolvingSymlinksInPath(), data: Data("{}".utf8)))
        #expect(result.diagnostics.count == 1)
    }

    @Test("bundled CLI targets its owning app without URL-handler registration")
    func bundledApplication() {
        #expect(CLIApplicationLocation.bundledApp(for: URL(fileURLWithPath: "/Applications/FIELDNOTES.app/Contents/MacOS/fieldnotes"))?.path == "/Applications/FIELDNOTES.app")
        #expect(CLIApplicationLocation.bundledApp(for: URL(fileURLWithPath: "/usr/local/bin/fieldnotes")) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
