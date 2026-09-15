import Foundation
import Testing
import WebKit
@testable import FieldnotesApp

@Suite("Native editor bridge", .serialized)
@MainActor
struct EditorBridgeTests {
    @Test("strict envelopes reject missing, extra, unknown, and negative fields", arguments: [
        #"{"kind":"transaction","documentID":"doc","baseRevision":0,"revision":1,"payload":{"text":"x","selection":{"anchor":1,"head":1},"editKind":"done"},"extra":true}"#,
        #"{"kind":"mystery","documentID":"doc","baseRevision":0,"revision":1,"payload":{}}"#,
        #"{"kind":"transaction","documentID":"doc","baseRevision":-1,"revision":0,"payload":{"text":"x","selection":{"anchor":1,"head":1},"editKind":"done"}}"#,
        #"{"kind":"transaction","documentID":"doc","baseRevision":0,"revision":1,"payload":{"text":"x","selection":{"anchor":1,"head":1},"editKind":"done","surprise":1}}"#,
        #"{"kind":"selection","documentID":"doc","baseRevision":0,"revision":0,"payload":{"selection":{"anchor":0}}}"#,
    ])
    func strictDecoding(source: String) {
        let body = try! JSONSerialization.jsonObject(with: Data(source.utf8))
        #expect(throws: BridgeProtocolError.self) {
            try EditorBridgeRequest.decode(body: body)
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditorBridgeRequest.self, from: Data(source.utf8))
        }
    }

    @Test("ready returns a JSON-safe snapshot and wrong documents disclose no text")
    func readyAndWrongDocument() throws {
        let state = try DocumentState(data: Data("secret 🧭".utf8))
        let session = EditorSession(state: state, documentID: "doc")

        let ready = try request(#"{"kind":"ready","documentID":"","baseRevision":0,"revision":0,"payload":{}}"#)
        let snapshot = session.receive(ready)
        #expect(snapshot["kind"] as? String == "snapshot")
        #expect(snapshot["documentID"] as? String == "doc")
        #expect(snapshot["text"] as? String == "secret 🧭")
        #expect(JSONSerialization.isValidJSONObject(snapshot))

        let wrong = try request(#"{"kind":"requestSnapshot","documentID":"other","baseRevision":0,"revision":0,"payload":{}}"#)
        let rejection = session.receive(wrong)
        #expect(rejection["kind"] as? String == "rejected")
        #expect(rejection["text"] == nil)
        #expect(rejection["revision"] == nil)
    }

    @Test("valid edits, undo, and redo advance only the native revision")
    func orderedEdits() throws {
        let state = try DocumentState(data: Data("one".utf8))
        let session = EditorSession(state: state, documentID: "doc")

        for (base, revision, text, editKind) in [
            (0, 1, "two", "done"),
            (1, 2, "one", "undone"),
            (2, 3, "two", "redone"),
        ] {
            let reply = session.receive(try request(transaction(base, revision, text, editKind)))
            #expect(reply["kind"] as? String == "ack")
            #expect(reply["revision"] as? Int == revision)
        }

        #expect(state.editorText == "two")
        #expect(state.revision == 3)
    }

    @Test("selection-only updates preserve revision and UTF-16 offsets")
    func selectionOnly() throws {
        let state = try DocumentState(data: Data("A😀B".utf8))
        let session = EditorSession(state: state, documentID: "doc")
        let reply = session.receive(try request(#"{"kind":"selection","documentID":"doc","baseRevision":0,"revision":0,"payload":{"selection":{"anchor":3,"head":1}}}"#))

        #expect(reply["kind"] as? String == "ack")
        #expect(reply["revision"] as? Int == 0)
        #expect(state.selection == .init(anchor: 3, head: 1))
        #expect(state.revision == 0)
    }

    @Test("stale, future, and replayed transactions receive authoritative snapshots")
    func revisionMismatchResyncs() throws {
        let state = try DocumentState(data: Data("zero".utf8))
        let session = EditorSession(state: state, documentID: "doc")
        _ = session.receive(try request(transaction(0, 1, "one", "done")))

        for source in [
            transaction(0, 1, "stale", "done"),
            transaction(5, 6, "future", "done"),
            transaction(1, 1, "duplicate", "done"),
        ] {
            let reply = session.receive(try request(source))
            #expect(reply["kind"] as? String == "snapshot")
            #expect(reply["text"] as? String == "one")
            #expect(reply["revision"] as? Int == 1)
        }
        #expect(state.editorText == "one")
    }

    @Test("frame and body validation rejects subframes before decoding")
    func mainFrameValidation() throws {
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"ready","documentID":"","baseRevision":0,"revision":0,"payload":{}}"#.utf8))
        #expect(throws: BridgeProtocolError.self) { try EditorBridgeRequest.validate(body: body, isMainFrame: false) }
        #expect(try EditorBridgeRequest.validate(body: body, isMainFrame: true).kind == .ready)
    }

    @Test("web configuration is nonpersistent and registers then tears down one page-world handler")
    func webConfigurationAndTeardown() {
        let state = DocumentState()
        let session = EditorSession(state: state, documentID: "doc")
        let registration = EditorWebConfiguration.make(session: session)

        #expect(registration.configuration.websiteDataStore !== WKWebsiteDataStore.default())
        #expect(registration.handler.isRegistered)
        registration.teardown()
        #expect(!registration.handler.isRegistered)
    }

    @Test("a document window owns one stable editor session")
    func stableWindowSession() {
        _ = NSApplication.shared
        let state = DocumentState()
        let controller = DocumentWindowController(state: state)
        #expect(controller.session.state === state)
        #expect(controller.session === controller.session)
    }

    @Test("reply handler holds the session weakly")
    func weakSessionLifecycle() {
        weak var weakSession: EditorSession?
        var registration: EditorWebRegistration?
        do {
            let session = EditorSession(state: DocumentState(), documentID: "doc")
            weakSession = session
            registration = EditorWebConfiguration.make(session: session)
        }
        #expect(weakSession == nil)
        registration?.teardown()
    }

    @Test("navigation permits only the exact editor page and user HTTPS links")
    func navigationPolicy() {
        let root = URL(fileURLWithPath: "/bundle/editor-web", isDirectory: true)
        let index = root.appendingPathComponent("index.html")
        #expect(EditorNavigationPolicy.decide(url: index, editorRoot: root, isUserLink: false) == .allow)
        #expect(EditorNavigationPolicy.decide(url: root.appendingPathComponent("other.html"), editorRoot: root, isUserLink: false) == .cancel)
        #expect(EditorNavigationPolicy.decide(url: URL(string: "https://example.com")!, editorRoot: root, isUserLink: true) == .openExternally)
        #expect(EditorNavigationPolicy.decide(url: URL(string: "https://example.com")!, editorRoot: root, isUserLink: false) == .cancel)
        #expect(EditorNavigationPolicy.decide(url: URL(string: "http://example.com")!, editorRoot: root, isUserLink: true) == .cancel)
    }

    private func request(_ source: String) throws -> EditorBridgeRequest {
        try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8)))
    }

    private func transaction(_ base: Int, _ revision: Int, _ text: String, _ editKind: String) -> String {
        #"{"kind":"transaction","documentID":"doc","baseRevision":\#(base),"revision":\#(revision),"payload":{"text":"\#(text)","selection":{"anchor":0,"head":\#(text.utf16.count)},"editKind":"\#(editKind)"}}"#
    }
}
