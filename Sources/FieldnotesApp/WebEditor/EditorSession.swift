import Foundation

@MainActor
final class EditorSession {
    let state: DocumentState
    let documentID: String

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
}
