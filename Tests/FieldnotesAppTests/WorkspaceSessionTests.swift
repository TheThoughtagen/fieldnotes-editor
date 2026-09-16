import Foundation
import Testing
@testable import FieldnotesApp
@testable import FieldnotesCore

@Suite("Workspace editor session", .serialized)
@MainActor
struct WorkspaceSessionTests {
    @Test("CRLF open positions use editor logical lines")
    func crlfPosition() throws {
        let root = FileManager.default.temporaryDirectory
        let session = EditorSession(state: try DocumentState(data: Data("first\r\nsecond\r\n".utf8)))
        session.installOpenContext(.init(context: .init(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: .source, line: 2, column: 3))
        let context = try #require(session.snapshot()["openContext"] as? [String: Any])
        #expect(context["line"] as? Int == 2)
        #expect(context["column"] as? Int == 3)
    }

    @Test("saving at current location preserves the explicitly selected schema")
    func savePreservesExplicitSchema() throws {
        let root = FileManager.default.temporaryDirectory
        let file = root.appendingPathComponent("same-\(UUID()).md")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let state = DocumentState()
        let session = EditorSession(state: state)
        session.installOpenContext(.init(context: .init(workspace: root, document: file, schema: .loaded(url: root.appendingPathComponent("explicit.json"), data: Data("{}".utf8)), localAssetPolicy: .workspace), requestedMode: .source, line: nil, column: nil))
        let generation = session.contextGeneration
        try session.refreshDocumentLocation(file)
        #expect(session.contextGeneration == generation)
        #expect(session.schemaStatus == .checking)
    }

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

    @Test("non-Markdown directories consume the traversal budget")
    func traversalBudget() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var deep = root
        for i in 0..<12 {
            deep = deep.appendingPathComponent("level-\(i)")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data().write(to: deep.appendingPathComponent("noise.txt"))
        }
        try Data("## Outside budget".utf8).write(to: deep.appendingPathComponent("target.md"))
        let index = WorkspaceIndex(root: root, maximumFiles: 2, maximumEntries: 5)
        #expect(index.search("target").isEmpty)
    }

    @Test("one line cannot exceed the per-document content record budget")
    func contentRecordBudget() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let links = (0..<240).map { "[label\($0)](https://example.test)" }.joined(separator: " ")
        try Data(links.utf8).write(to: root.appendingPathComponent("many.md"))
        let index = WorkspaceIndex(root: root)
        #expect(index.search("label199").count == 1)
        #expect(index.search("label200").isEmpty)
        #expect(index.search("label239").isEmpty)
    }

    @Test("Setext H2 and full collapsed shortcut reference links retain source lines")
    func standardMarkdownSearch() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "Calibration\n-----------\n\n[Handbook][docs]\n[docs][]\n[docs]\n\n[docs]: https://example.test\n\n```md\nHidden\n------\n[Hidden][docs]\n```"
        try Data(source.utf8).write(to: root.appendingPathComponent("other.md"))
        let index = WorkspaceIndex(root: root)
        let heading = try #require(index.search("Calibration").first)
        #expect(index.line(id: heading.id) == 1)
        let link = try #require(index.search("Handbook").first)
        #expect(index.line(id: link.id) == 4)
        #expect(index.search("docs").compactMap { index.line(id: $0.id) }.sorted() == [5, 6])
        #expect(index.search("Hidden").isEmpty)
    }

    @Test("background indexing cannot install results from a superseded workspace")
    func asynchronousIndexGeneration() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), current = root.appendingPathComponent("current")
        for directory in [old, current] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data().write(to: old.appendingPathComponent("old.md"))
        try Data().write(to: current.appendingPathComponent("current.md"))
        let probe = IndexBuildProbe()
        defer { probe.release.signal() }
        let session = EditorSession(state: DocumentState(), documentID: "doc", indexBuilder: { probe.build($0) })
        let oldContext = WorkspaceContext(workspace: old, document: nil, schema: .none, localAssetPolicy: .workspace)
        session.installOpenContext(.init(context: oldContext, requestedMode: nil, line: nil, column: nil))
        let oldRequest = try decode(#"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"","generation":1}}"#)
        let oldSearch = Task { (await session.prepareWorkspaceSearchResponse(to: oldRequest)).reply["kind"] as? String }
        for _ in 0..<100 {
            if probe.hasStarted { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(probe.hasStarted)
        #expect(!probe.wasMainThread)
        let newContext = WorkspaceContext(workspace: current, document: nil, schema: .none, localAssetPolicy: .workspace)
        session.installOpenContext(.init(context: newContext, requestedMode: .preview, line: nil, column: nil))
        #expect(session.presentationMode == "preview")
        let newRequest = try decode(#"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"","generation":2}}"#)
        let first = await session.prepareWorkspaceSearchResponse(to: newRequest)
        #expect((first.reply["results"] as? [[String: String]])?.map { $0["title"] } == ["current.md"])
        probe.release.signal()
        #expect(await oldSearch.value == "rejected")
        let replay = await session.prepareWorkspaceSearchResponse(to: newRequest)
        #expect((replay.reply["results"] as? [[String: String]])?.map { $0["title"] } == ["current.md"])
    }

    @Test("the WebKit handler returns workspace results after background indexing")
    func asynchronousSearchHandler() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("note.md"))
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        let handler = WeakEditorReplyHandler(session: session)
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"workspaceSearch","documentID":"doc","baseRevision":0,"revision":0,"payload":{"query":"note","generation":1}}"#.utf8))
        var events: [String] = []
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            handler.handle(body: body, isMainFrame: true) { value, error in
                events.append("reply")
                let reply = value as? [String: Any]
                #expect(error == nil)
                #expect(reply?["kind"] as? String == "workspaceResults")
                #expect((reply?["results"] as? [[String: String]])?.first?["title"] == "note.md")
                continuation.resume()
            }
            events.append("returned")
        }
        #expect(events == ["returned", "reply"])
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func decode(_ source: String) throws -> EditorBridgeRequest {
        try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8)))
    }
}

private final class IndexBuildProbe: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var mainThread = false
    private var didStart = false
    var hasStarted: Bool { lock.withLock { didStart } }
    var wasMainThread: Bool { lock.withLock { mainThread } }
    func build(_ root: URL) -> WorkspaceIndex {
        if root.lastPathComponent == "old" {
            lock.withLock { mainThread = Thread.isMainThread; didStart = true }
            _ = release.wait(timeout: .now() + 2)
        }
        return WorkspaceIndex(root: root)
    }
}

@Suite struct SearchNewlineTests {
    @Test func equivalentLineEndingsPreserveSearchDestinations() {
        let source = "---\ntags: [tag]\n---\n## Heading\n[link](target)\n"
        let baseline = MarkdownSearchStructure.entries(source, limit: 20)
        #expect(baseline.count == 3)
        for newline in ["\r\n", "\r"] {
            let actual = MarkdownSearchStructure.entries(source.replacingOccurrences(of: "\n", with: newline), limit: 20)
            #expect(actual.map(\.title) == baseline.map(\.title))
            #expect(actual.map(\.line) == baseline.map(\.line))
        }
    }
}
