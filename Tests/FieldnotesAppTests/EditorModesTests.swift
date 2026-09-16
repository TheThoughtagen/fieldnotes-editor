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
