import AppKit
import Foundation
import Testing
@testable import FieldnotesApp

@Suite("Native Markdown documents", .serialized)
@MainActor
struct DocumentStateTests {
    @Test("unchanged CRLF source round-trips byte-for-byte")
    func unchangedDocumentRoundTripsExactly() throws {
        let bytes = Data("---\r\ntitle: X\r\n---\r\nBody\r\n".utf8)
        let state = try DocumentState(data: bytes)

        #expect(state.baseData == bytes)
        #expect(state.baseText == "---\r\ntitle: X\r\n---\r\nBody\r\n")
        #expect(try state.serializedData() == bytes)
    }

    @Test("BOM and missing final newline survive edits undone to the baseline")
    func undoToBaselineRestoresOriginalBytes() throws {
        let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("Body".utf8)
        let state = try DocumentState(data: bytes)

        state.acceptEditorText("Body changed", selection: .init(anchor: 12, head: 12), kind: .done)
        state.acceptEditorText(state.baseText, selection: .init(anchor: 4, head: 4), kind: .undone)

        #expect(try state.serializedData() == bytes)
    }

    @Test("invalid UTF-8 reports a typed error without mutating state")
    func invalidUTF8DoesNotMutateState() throws {
        let state = try DocumentState(data: Data("valid".utf8))
        let originalRevision = state.revision

        #expect(throws: DocumentStateError.invalidUTF8) {
            try state.replaceFromDisk(Data([0xC3, 0x28]))
        }
        #expect(state.baseText == "valid")
        #expect(state.editorText == "valid")
        #expect(state.revision == originalRevision)
    }

    @Test("text edits advance revision and report undo semantics")
    func textEditsAdvanceRevisionAndReportKinds() throws {
        let state = try DocumentState(data: Data("one".utf8))
        var edits: [DocumentEditKind] = []
        state.onEdit = { edits.append($0) }

        state.acceptEditorText("two", selection: .init(anchor: 3, head: 3), kind: .done)
        state.acceptEditorText("one", selection: .init(anchor: 0, head: 3), kind: .undone)
        state.acceptEditorText("two", selection: .init(anchor: 3, head: 3), kind: .redone)

        #expect(state.revision == 3)
        #expect(edits == [.done, .undone, .redone])
    }

    @Test("selection-only transactions neither revise nor dirty the document")
    func selectionOnlyDoesNotAdvanceRevision() throws {
        let state = try DocumentState(data: Data("one".utf8))
        var editCount = 0
        state.onEdit = { _ in editCount += 1 }

        state.updateSelection(.init(anchor: 1, head: 2))
        state.acceptEditorText("one", selection: .init(anchor: 2, head: 2), kind: .done)

        #expect(state.selection == .init(anchor: 2, head: 2))
        #expect(state.revision == 0)
        #expect(editCount == 0)
    }

    @Test("composed source changing to decomposed Unicode is an exact edit")
    func composedToDecomposedUnicodeIsAnEdit() throws {
        let composedBytes = Data([0xC3, 0xA9])
        let decomposedText = "e\u{301}"
        let decomposedBytes = Data([0x65, 0xCC, 0x81])
        let state = try DocumentState(data: composedBytes)
        var edits: [DocumentEditKind] = []
        state.onEdit = { edits.append($0) }

        state.acceptEditorText(
            decomposedText,
            selection: .init(anchor: 2, head: 2),
            kind: .done
        )

        #expect(Data(state.editorText.utf8) == decomposedBytes)
        #expect(state.selection == .init(anchor: 2, head: 2))
        #expect(state.revision == 1)
        #expect(edits == [.done])
        #expect(try state.serializedData() == decomposedBytes)
    }

    @Test("decomposed source changing to composed Unicode dirties the document")
    func decomposedToComposedUnicodeIsAnEdit() throws {
        let decomposedBytes = Data([0x65, 0xCC, 0x81])
        let composedText = "\u{E9}"
        let composedBytes = Data([0xC3, 0xA9])
        let document = FieldnotesDocument()
        try document.read(from: decomposedBytes, ofType: markdownType)

        document.state.acceptEditorText(
            composedText,
            selection: .init(anchor: 1, head: 1),
            kind: .done
        )

        #expect(Data(document.state.editorText.utf8) == composedBytes)
        #expect(document.state.selection == .init(anchor: 1, head: 1))
        #expect(document.state.revision == 2)
        #expect(document.isDocumentEdited)
        #expect(try document.state.serializedData() == composedBytes)
    }

    @Test("disk replacement preserves state identity, clamps selection, and avoids edit callbacks")
    func diskReplacementMutatesPersistentState() throws {
        let state = try DocumentState(data: Data("long text".utf8))
        let identity = ObjectIdentifier(state)
        state.updateSelection(.init(anchor: 9, head: 4))
        var editCount = 0
        state.onEdit = { _ in editCount += 1 }

        try state.replaceFromDisk(Data("new".utf8))

        #expect(ObjectIdentifier(state) == identity)
        #expect(state.baseData == Data("new".utf8))
        #expect(state.baseText == "new")
        #expect(state.editorText == "new")
        #expect(state.selection == .init(anchor: 3, head: 3))
        #expect(state.revision == 1)
        #expect(editCount == 0)
    }

    @Test("saved snapshots become the exact baseline without discarding later edits")
    func savePromotionRetainsNewerText() throws {
        let state = try DocumentState(data: Data("base\r\n".utf8))
        state.acceptEditorText("saved", selection: .init(anchor: 5, head: 5), kind: .done)
        let snapshot = try state.saveSnapshot()
        state.acceptEditorText("newer", selection: .init(anchor: 5, head: 5), kind: .done)

        state.promoteSavedSnapshot(snapshot)

        #expect(state.baseData == Data("saved".utf8))
        #expect(state.baseText == "saved")
        #expect(state.editorText == "newer")
        #expect(state.revision == 2)
        #expect(try state.serializedData() == Data("newer".utf8))
    }

    @Test("document reads retain the persistent observable state")
    func documentReadRetainsStateIdentity() throws {
        let document = FieldnotesDocument()
        let identity = ObjectIdentifier(document.state)

        try document.read(from: Data("replacement".utf8), ofType: markdownType)

        #expect(ObjectIdentifier(document.state) == identity)
        #expect(document.state.editorText == "replacement")
    }

    @Test("editor edit, undo, and redo update NSDocument change accounting")
    func documentChangeAccountingTracksEditKinds() throws {
        let document = FieldnotesDocument()
        try document.read(from: Data("one".utf8), ofType: markdownType)

        document.state.acceptEditorText("two", selection: .init(anchor: 3, head: 3), kind: .done)
        #expect(document.isDocumentEdited)

        document.state.acceptEditorText("one", selection: .init(anchor: 3, head: 3), kind: .undone)
        #expect(!document.isDocumentEdited)

        document.state.acceptEditorText("two", selection: .init(anchor: 3, head: 3), kind: .redone)
        #expect(document.isDocumentEdited)
    }

    @Test("faulted safe write leaves the original file byte-identical")
    func faultedSafeWritePreservesOriginal() throws {
        let original = Data("original\r\n".utf8)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        try original.write(to: url)
        let document = FieldnotesDocument(byteWriter: { data, destination in
            try data.prefix(2).write(to: destination)
            throw InjectedWriteError()
        })
        try document.read(from: Data("replacement".utf8), ofType: markdownType)

        #expect(throws: InjectedWriteError.self) {
            try document.writeSafely(to: url, ofType: markdownType, for: .saveOperation)
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("successful safe write replaces the destination")
    func successfulSafeWriteReplacesDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        try Data("original".utf8).write(to: url)
        let document = FieldnotesDocument()
        try document.read(from: Data("replacement".utf8), ofType: markdownType)

        try document.writeSafely(to: url, ofType: markdownType, for: .saveOperation)

        #expect(try Data(contentsOf: url) == Data("replacement".utf8))
    }

    @Test("the document opts into autosave and Versions without concurrent I/O")
    func documentIOPolicy() {
        #expect(FieldnotesDocument.autosavesInPlace)
        #expect(FieldnotesDocument.preservesVersions)
        #expect(!FieldnotesDocument.canConcurrentlyReadDocuments(ofType: markdownType))

        let document = FieldnotesDocument()
        #expect(!document.canAsynchronouslyWrite(
            to: URL(fileURLWithPath: "/tmp/note.md"),
            ofType: markdownType,
            for: .saveOperation
        ))
    }

    @Test("document windows retain the persistent state and native geometry")
    func documentWindowUsesPersistentState() throws {
        _ = NSApplication.shared
        let document = FieldnotesDocument()

        document.makeWindowControllers()

        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        let window = try #require(controller.window)
        #expect(controller.state === document.state)
        #expect(window.frame.size == NSSize(width: 960, height: 720))
        #expect(window.minSize == NSSize(width: 640, height: 420))
        #expect(window.styleMask.contains([.titled, .closable, .miniaturizable, .resizable]))
    }

    private let markdownType = "net.daringfireball.markdown"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fieldnotes-document-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct InjectedWriteError: Error {}
