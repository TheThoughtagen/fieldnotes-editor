import AppKit
import Foundation
import Testing
@testable import FieldnotesApp

@Suite("Editor modes and native actions", .serialized)
@MainActor
struct EditorModesTests {
    @Test("native action envelopes are closed and document scoped")
    func actionEnvelope() throws {
        let source = #"{"kind":"action","documentID":"doc","baseRevision":2,"revision":2,"payload":{"action":"save"}}"#
        let request = try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8)))
        #expect(request.kind == .action)
        #expect(request.payload.action == "save")

        for invalid in [
            #"{"kind":"action","documentID":"doc","baseRevision":2,"revision":2,"payload":{"action":"write-path"}}"#,
            #"{"kind":"action","documentID":"doc","baseRevision":2,"revision":2,"payload":{"action":"save","path":"/tmp/x"}}"#,
            #"{"kind":"action","documentID":"doc","baseRevision":2,"revision":3,"payload":{"action":"quit"}}"#,
        ] {
            #expect(throws: (any Error).self) {
                try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(invalid.utf8)))
            }
        }
    }

    @Test("preparing an action reply never performs its side effect eagerly")
    func actionIsNotEager() throws {
        let state = try DocumentState(data: Data("one".utf8))
        let session = EditorSession(state: state, documentID: "doc")
        var events: [String] = []
        session.onNativeAction = { _ in events.append("action") }
        let source = #"{"kind":"action","documentID":"doc","baseRevision":0,"revision":0,"payload":{"action":"save"}}"#

        let reply = session.receive(try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8))))
        events.append("reply")

        #expect(reply["kind"] as? String == "ack")
        #expect(events == ["reply"])
    }

    @Test("reply completes before deferred quit tears down its target")
    func replyBeforeQuit() async throws {
        let session = EditorSession(state: try DocumentState(data: Data("one".utf8)), documentID: "doc")
        let handler = WeakEditorReplyHandler(session: session)
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"action","documentID":"doc","baseRevision":0,"revision":0,"payload":{"action":"quit"}}"#.utf8))
        var events: [String] = []

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.onNativeAction = { action in
                events.append("action:\(action.rawValue)")
                handler.markRemoved()
                continuation.resume()
            }
            handler.handle(body: body, isMainFrame: true) { reply, error in
                events.append("reply")
                #expect((reply as? [String: Any])?["kind"] as? String == "ack")
                #expect(error == nil)
            }
            #expect(events == ["reply"])
        }

        #expect(events == ["reply", "action:quit"])
        #expect(!handler.isRegistered)
    }

    @Test("invalid wrong-document and stale actions never schedule native effects")
    func rejectedActionsHaveNoEffect() async throws {
        let session = EditorSession(state: try DocumentState(data: Data("one".utf8)), documentID: "doc")
        let handler = WeakEditorReplyHandler(session: session)
        var actions: [NativeEditorAction] = []
        var replyCount = 0
        session.onNativeAction = { actions.append($0) }
        let sources = [
            #"{"kind":"action","documentID":"doc","baseRevision":0,"revision":0,"payload":{"action":"save","path":"/tmp/no"}}"#,
            #"{"kind":"action","documentID":"other","baseRevision":0,"revision":0,"payload":{"action":"save"}}"#,
            #"{"kind":"action","documentID":"doc","baseRevision":1,"revision":1,"payload":{"action":"quit"}}"#,
        ]

        for source in sources {
            let body = try JSONSerialization.jsonObject(with: Data(source.utf8))
            handler.handle(body: body, isMainFrame: true) { _, _ in replyCount += 1 }
        }
        await Task.yield()
        await Task.yield()

        #expect(replyCount == sources.count)
        #expect(actions.isEmpty)
    }

    @Test("status messages validate bounded enum and positive coordinates")
    func statusEnvelope() throws {
        let source = #"{"kind":"status","documentID":"doc","baseRevision":0,"revision":0,"payload":{"presentationMode":"preview","vimMode":"normal","line":1,"column":1,"wordCount":7}}"#
        let request = try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(source.utf8)))
        #expect(request.payload.presentationMode == "preview")
        #expect(request.payload.wordCount == 7)
        let invalid = #"{"kind":"status","documentID":"doc","baseRevision":0,"revision":0,"payload":{"presentationMode":"preview","vimMode":"evil","line":1,"column":1,"wordCount":7}}"#
        #expect(throws: (any Error).self) {
            try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(invalid.utf8)))
        }
        let state = try DocumentState(data: Data("one".utf8))
        let session = EditorSession(state: state, documentID: "doc")
        let outOfRange = #"{"kind":"status","documentID":"doc","baseRevision":0,"revision":0,"payload":{"presentationMode":"preview","vimMode":"normal","line":99,"column":1,"wordCount":1}}"#
        let reply = session.receive(try EditorBridgeRequest.decode(body: JSONSerialization.jsonObject(with: Data(outOfRange.utf8))))
        #expect(reply["kind"] as? String == "snapshot")
        #expect(session.presentationMode == "focus")
        #expect(session.schemaStatus == .unavailable)
    }

    @Test("application commands expose deterministic mode shortcuts")
    func commandShortcuts() {
        #expect(EditorCommand.focus.shortcut == "1")
        #expect(EditorCommand.source.shortcut == "2")
        #expect(EditorCommand.preview.shortcut == "3")
        #expect(EditorCommand.cycleMode.shortcut == "\\")
    }
}
