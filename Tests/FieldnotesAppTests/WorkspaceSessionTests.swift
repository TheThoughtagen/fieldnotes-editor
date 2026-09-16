import Foundation
import Testing
@testable import FieldnotesApp
@testable import FieldnotesCore

@Suite("Workspace editor session", .serialized)
@MainActor
struct WorkspaceSessionTests {
    @Test("open context survives delivery loss until generation acknowledgement")
    func oneShotContext() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-context-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("note.md")
        try Data("# A".utf8).write(to: document)
        let context = WorkspaceContext(workspace: root, document: document, schema: .diagnostic("bad schema"), localAssetPolicy: .workspace)
        let session = EditorSession(state: try DocumentState(data: Data("# A".utf8)), documentID: "doc")
        session.installOpenContext(.init(context: context, requestedMode: .preview, line: 99, column: 8))

        let ready = try decode(#"{"kind":"ready","documentID":"","baseRevision":0,"revision":0,"payload":{}}"#)
        let first = session.receive(ready)
        let payload = try #require(first["openContext"] as? [String: Any])
        #expect(payload["generation"] as? Int == 1)
        #expect(payload["mode"] as? String == "preview")
        #expect(payload["line"] as? Int == 1)
        #expect(payload["column"] as? Int == 4)
        #expect((payload["diagnostics"] as? [String])?.count == 2)

        let second = session.receive(ready)
        #expect((second["openContext"] as? [String: Any])?["generation"] as? Int == 1)
        let acknowledgement = try decode(#"{"kind":"contextApplied","documentID":"doc","baseRevision":0,"revision":0,"payload":{"generation":1}}"#)
        _ = session.receive(acknowledgement)
        let replay = try #require(session.snapshot()["openContext"] as? [String: Any])
        #expect(replay["line"] is NSNull)
        #expect(replay["mode"] as? String == "preview")
    }

    @Test("workspace index exposes opaque IDs and revalidates removed files")
    func boundedOpaqueIndex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("日本語 note.md")
        try Data("# Heading".utf8).write(to: document)
        let index = WorkspaceIndex(root: root, maximumFiles: 20)

        let result = try #require(index.search("日本語", limit: 10).first)
        #expect(result.title == "日本語 note.md")
        #expect(!result.id.contains("/"))
        #expect(result.id != document.path)
        #expect(index.resolve(id: result.id) == document.resolvingSymlinksInPath())

        try FileManager.default.removeItem(at: document)
        #expect(index.resolve(id: result.id) == nil)
    }

    @Test("workspace bridge messages are closed, bounded, and generation scoped")
    func workspaceBridgeEnvelope() throws {
        let valid = try decode(#"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"readme","generation":2}}"#)
        #expect(valid.payload.query == "readme")
        #expect(valid.payload.generation == 2)

        for source in [
            #"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"readme","generation":2,"path":"/tmp/secret"}}"#,
            #"{"kind":"workspaceOpen","documentID":"doc","baseRevision":0,"revision":0,"payload":{"resultID":"../../secret","generation":2}}"#,
            #"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","generation":2}}"#,
        ] {
            #expect(throws: (any Error).self) { try decode(source) }
        }
    }

    @Test("warm contexts notify delivery and remembered modes survive new sessions")
    func warmRememberedMode() throws {
        let suite = "fieldnotes-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace)
        let session = EditorSession(state: DocumentState(), documentID: "doc", defaults: defaults)
        var notifications = 0
        session.onContextChanged = { notifications += 1 }
        session.installOpenContext(.init(context: context, requestedMode: .source, line: nil, column: nil))
        _ = session.receive(try decode(#"{"kind":"contextApplied","documentID":"doc","baseRevision":0,"revision":0,"payload":{"generation":1}}"#))
        _ = session.receive(try decode(#"{"kind":"status","documentID":"doc","baseRevision":0,"revision":0,"payload":{"presentationMode":"preview","vimMode":"normal","line":1,"column":1,"wordCount":0}}"#))
        let reopened = EditorSession(state: DocumentState(), defaults: defaults)
        reopened.installOpenContext(.init(context: context, requestedMode: nil, line: nil, column: nil))
        #expect(reopened.presentationMode == "preview")
        session.installOpenContext(.init(context: context, requestedMode: .focus, line: nil, column: nil))
        #expect(notifications == 2)
        #expect(session.presentationMode == "focus")
    }

    @Test("workspace search finds headings links tags outside the active document")
    func contentSearch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("---\ntags: [reliability]\n---\n## Calibration\n[Handbook](https://example.test)".utf8).write(to: root.appendingPathComponent("other.md"))
        let index = WorkspaceIndex(root: root)
        #expect(index.search("Calibration").first?.title.contains("Calibration") == true)
        #expect(index.search("Handbook").first?.title.contains("Handbook") == true)
        #expect(index.search("reliability").first?.title.contains("reliability") == true)
    }

    @Test("renderer schema status is accepted only for the active context")
    func schemaStatusDelivery() throws {
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        let request = try decode(#"{"kind":"schemaStatus","documentID":"doc","baseRevision":0,"revision":0,"payload":{"generation":1,"schemaState":"invalid"}}"#)
        #expect(session.receive(request)["kind"] as? String == "rejected")
    }

    private func decode(_ source: String) throws -> EditorBridgeRequest {
        try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8)))
    }
}
