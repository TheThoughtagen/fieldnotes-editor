import Foundation
import Observation

enum DocumentStateError: Error, Equatable {
    case invalidUTF8
}

struct EditorSelection: Equatable, Sendable {
    var anchor: Int
    var head: Int
}

enum DocumentEditKind: Equatable, Sendable {
    case done
    case undone
    case redone
}

struct DocumentSaveSnapshot: Equatable, Sendable {
    let data: Data
    let text: String
    let revision: Int
}

@MainActor
@Observable
final class DocumentState {
    @ObservationIgnored private(set) var baseData: Data
    private(set) var baseText: String
    private(set) var editorText: String
    private(set) var selection: EditorSelection
    private(set) var revision: Int
    @ObservationIgnored var onEdit: ((DocumentEditKind) -> Void)?

    init() {
        baseData = Data()
        baseText = ""
        editorText = ""
        selection = EditorSelection(anchor: 0, head: 0)
        revision = 0
    }

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentStateError.invalidUTF8
        }
        baseData = data
        baseText = text
        editorText = text
        selection = EditorSelection(anchor: 0, head: 0)
        revision = 0
    }

    func serializedData() throws -> Data {
        editorText == baseText ? baseData : Data(editorText.utf8)
    }

    func saveSnapshot() throws -> DocumentSaveSnapshot {
        DocumentSaveSnapshot(data: try serializedData(), text: editorText, revision: revision)
    }

    func promoteSavedSnapshot(_ snapshot: DocumentSaveSnapshot) {
        baseData = snapshot.data
        baseText = snapshot.text
    }

    func acceptEditorText(
        _ text: String,
        selection newSelection: EditorSelection,
        kind: DocumentEditKind
    ) {
        selection = clamped(newSelection, to: text)
        guard text != editorText else { return }
        editorText = text
        revision += 1
        onEdit?(kind)
    }

    func updateSelection(_ newSelection: EditorSelection) {
        selection = clamped(newSelection, to: editorText)
    }

    func replaceFromDisk(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DocumentStateError.invalidUTF8
        }
        let oldSelection = selection
        baseData = data
        baseText = text
        editorText = text
        selection = clamped(oldSelection, to: text)
        revision += 1
    }

    private func clamped(_ selection: EditorSelection, to text: String) -> EditorSelection {
        let upperBound = text.utf16.count
        return EditorSelection(
            anchor: min(max(selection.anchor, 0), upperBound),
            head: min(max(selection.head, 0), upperBound)
        )
    }
}
