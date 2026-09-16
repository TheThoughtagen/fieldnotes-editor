import Foundation
import Observation

enum NativeEditorAction: String, Sendable { case save, quit }

enum SchemaStatus: String, Sendable { case unavailable = "Schema —" }

enum EditorCommand: Sendable {
    case focus, source, preview, cycleMode, toggleVim
    var shortcut: Character { switch self { case .focus: "1"; case .source: "2"; case .preview: "3"; case .cycleMode: "\\"; case .toggleVim: "v" } }
}

@MainActor
@Observable final class EditorSession {
    let state: DocumentState
    let documentID: String
    private(set) var presentationMode = "focus"
    private(set) var vimMode = "normal"
    private(set) var line = 1
    private(set) var column = 1
    private(set) var wordCount = 0
    private(set) var schemaStatus: SchemaStatus = .unavailable
    var onNativeAction: ((NativeEditorAction) -> Void)?
    var sendCommand: ((EditorCommand) -> Void)?

    init(state: DocumentState, documentID: String = UUID().uuidString) {
        self.state = state
        self.documentID = documentID
    }

    func receive(_ request: EditorBridgeRequest) -> [String: Any] {
        if request.kind == .ready {
            guard request.documentID.isEmpty || request.documentID == documentID else { return rejection() }
            return snapshot()
        }
        guard request.documentID == documentID else { return rejection() }

        switch request.kind {
        case .ready:
            return snapshot()
        case .requestSnapshot:
            return snapshot()
        case .selection:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let selection = request.payload.selection
            else { return snapshot() }
            state.updateSelection(.init(anchor: selection.anchor, head: selection.head))
            return acknowledgement()
        case .transaction:
            guard request.baseRevision == state.revision,
                  request.revision == request.baseRevision + 1,
                  let text = request.payload.text,
                  let selection = request.payload.selection,
                  let rawKind = request.payload.editKind,
                  let kind = editKind(rawKind)
            else { return snapshot() }
            state.acceptEditorText(text, selection: .init(anchor: selection.anchor, head: selection.head), kind: kind)
            guard state.revision == request.revision else { return snapshot() }
            return acknowledgement()
        case .status:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let mode = request.payload.presentationMode, let vim = request.payload.vimMode,
                  let line = request.payload.line, let column = request.payload.column,
                  let words = request.payload.wordCount,
                  validStatusPosition(line: line, column: column)
            else { return snapshot() }
            presentationMode = mode
            vimMode = vim
            self.line = line
            self.column = column
            wordCount = words
            return acknowledgement()
        case .action:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let raw = request.payload.action, let action = NativeEditorAction(rawValue: raw)
            else { return snapshot() }
            onNativeAction?(action)
            return acknowledgement()
        }
    }

    func snapshot() -> [String: Any] {
        [
            "kind": "snapshot",
            "documentID": documentID,
            "revision": state.revision,
            "text": state.editorText,
            "selection": ["anchor": state.selection.anchor, "head": state.selection.head],
        ]
    }

    private func acknowledgement() -> [String: Any] {
        ["kind": "ack", "documentID": documentID, "revision": state.revision]
    }

    private func rejection() -> [String: Any] {
        ["kind": "rejected", "reason": "document"]
    }

    private func editKind(_ rawValue: String) -> DocumentEditKind? {
        switch rawValue {
        case "done": .done
        case "undone": .undone
        case "redone": .redone
        default: nil
        }
    }

    private func validStatusPosition(line: Int, column: Int) -> Bool {
        let lines = state.editorText.split(separator: "\n", omittingEmptySubsequences: false)
        guard line > 0, line <= lines.count else { return false }
        return column > 0 && column <= lines[line - 1].utf16.count + 1
    }
}
