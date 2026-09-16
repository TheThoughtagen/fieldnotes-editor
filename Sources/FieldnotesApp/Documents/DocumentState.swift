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
    private(set) var conflict: ConflictModel?
    var externalReadError: String?
    private(set) var diskWasDeleted = false
    var hasUnsavedText: Bool { !hasSameUTF8Bytes(editorText, baseText) || diskWasDeleted }
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
        hasSameUTF8Bytes(editorText, baseText) ? baseData : Data(editorText.utf8)
    }

    func saveSnapshot() throws -> DocumentSaveSnapshot {
        DocumentSaveSnapshot(data: try serializedData(), text: editorText, revision: revision)
    }

    func promoteSavedSnapshot(_ snapshot: DocumentSaveSnapshot) {
        baseData = snapshot.data
        baseText = snapshot.text
        diskWasDeleted = false
    }

    func acceptEditorText(
        _ text: String,
        selection newSelection: EditorSelection,
        kind: DocumentEditKind
    ) {
        selection = clamped(newSelection, to: text)
        guard !hasSameUTF8Bytes(text, editorText) else { return }
        editorText = text
        revision += 1
        if let conflict {
            self.conflict = ConflictModel(base: conflict.base, ours: text, theirs: conflict.theirs)
        }
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

    /// A repeated baseline/self-save notification must not disturb newer editor transactions.
    func acceptExternal(_ data: Data?) throws {
        if let data, String(data: data, encoding: .utf8) == nil { throw DocumentStateError.invalidUTF8 }
        externalReadError = nil
        if data == (diskWasDeleted ? nil : baseData), conflict == nil { return }
        if let conflict, conflict.theirs == data { return }
        if hasUnsavedText || conflict != nil || data == nil {
            conflict = ConflictModel(base: baseData, ours: editorText, theirs: data)
        } else if let data {
            let oldText = editorText
            let oldSelection = selection
            try replaceFromDisk(data)
            selection = mapped(oldSelection, from: oldText, to: editorText)
        }
    }

    /// IDs invalidate a pending confirmation if either version changes while it is shown.
    @discardableResult
    func resolveConflict(id: UUID, using resolution: ConflictResolution) throws -> Bool {
        guard let conflict, conflict.id == id else { return false }
        let selected: String
        switch resolution {
        case .editor: selected = editorText
        case .disk:
            guard let data = conflict.theirs, let text = String(data: data, encoding: .utf8) else { return false }
            selected = text
        case .merged(let text): selected = text
        }
        let oldText = editorText
        let oldSelection = selection
        baseData = conflict.theirs ?? Data()
        baseText = String(data: baseData, encoding: .utf8) ?? ""
        diskWasDeleted = conflict.theirs == nil
        editorText = selected
        selection = mapped(oldSelection, from: oldText, to: selected)
        self.conflict = nil
        revision += 1
        return true
    }

    /// CodeMirror uses LF-normalized UTF-16 offsets even when native source retains CRLF/CR.
    private func logicalText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Map a single changed span in logical UTF-16 coordinates, retaining common text.
    private func mapped(_ selection: EditorSelection, from old: String, to new: String) -> EditorSelection {
        let before = Array(logicalText(old).utf16), after = Array(logicalText(new).utf16)
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix,
              before[before.count - suffix - 1] == after[after.count - suffix - 1] { suffix += 1 }
        func position(_ offset: Int) -> Int {
            let mapped: Int
            if offset < prefix { mapped = offset }
            else if offset >= before.count - suffix { mapped = offset + after.count - before.count }
            else { mapped = prefix + min(offset - prefix, after.count - prefix - suffix) }
            var valid = min(max(mapped, 0), after.count)
            if valid > 0, valid < after.count, (0xDC00...0xDFFF).contains(after[valid]),
               (0xD800...0xDBFF).contains(after[valid - 1]) { valid -= 1 }
            return valid
        }
        return EditorSelection(anchor: position(selection.anchor), head: position(selection.head))
    }

    private func clamped(_ selection: EditorSelection, to text: String) -> EditorSelection {
        let upperBound = logicalText(text).utf16.count
        return EditorSelection(
            anchor: min(max(selection.anchor, 0), upperBound),
            head: min(max(selection.head, 0), upperBound)
        )
    }

    private func hasSameUTF8Bytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }
}
