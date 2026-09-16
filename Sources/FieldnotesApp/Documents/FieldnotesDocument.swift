import AppKit
import Foundation
import FieldnotesCore

typealias DocumentByteWriter = (_ data: Data, _ destination: URL) throws -> Void

@objc(FieldnotesDocument)
final class FieldnotesDocument: NSDocument {
    let state: DocumentState
    private let byteWriter: DocumentByteWriter

    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        false
    }

    override init() {
        state = DocumentState()
        byteWriter = { data, destination in
            try data.write(to: destination, options: [])
        }
        super.init()
        connectChangeAccounting()
    }

    init(byteWriter: @escaping DocumentByteWriter) {
        state = DocumentState()
        self.byteWriter = byteWriter
        super.init()
        connectChangeAccounting()
    }

    override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        false
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try MainActor.assumeIsolated {
            try state.replaceFromDisk(data)
        }
    }

    nonisolated override func data(ofType typeName: String) throws -> Data {
        dispatchPrecondition(condition: .onQueue(.main))
        return try MainActor.assumeIsolated {
            try state.serializedData()
        }
    }

    nonisolated override func write(to url: URL, ofType typeName: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try MainActor.assumeIsolated {
            try byteWriter(state.serializedData(), url)
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let snapshot: DocumentSaveSnapshot
        do {
            snapshot = try state.saveSnapshot()
        } catch {
            completionHandler(error)
            return
        }

        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, saveOperation != .saveToOperation {
                self?.state.promoteSavedSnapshot(snapshot)
                for case let controller as DocumentWindowController in self?.windowControllers ?? [] {
                    try? controller.session.refreshDocumentLocation(url)
                    controller.workspaceURL = controller.session.currentWorkspaceURL
                }
            }
            completionHandler(error)
        }
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(state: state)
        if let fileURL, let context = try? WorkspaceResolver().resolve(input: fileURL) {
            controller.workspaceURL = context.workspace
            controller.session.installOpenContext(.init(context: context, requestedMode: nil, line: nil, column: nil))
        } else {
            let unsaved = WorkspaceContext(
                workspace: URL(fileURLWithPath: "/Fieldnotes Unsaved", isDirectory: true),
                document: nil,
                schema: .none,
                localAssetPolicy: .documentDirectory
            )
            controller.session.installOpenContext(.init(context: unsaved, requestedMode: nil, line: nil, column: nil))
        }
        addWindowController(controller)
    }

    nonisolated override func presentedItemDidMove(to newURL: URL) {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            super.presentedItemDidMove(to: newURL)
            for case let controller as DocumentWindowController in windowControllers {
                try? controller.session.refreshDocumentLocation(newURL)
                controller.workspaceURL = controller.session.currentWorkspaceURL
            }
        }
    }

    private func connectChangeAccounting() {
        state.onEdit = { [weak self] kind in
            let change: NSDocument.ChangeType = switch kind {
            case .done: .changeDone
            case .undone: .changeUndone
            case .redone: .changeRedone
            }
            self?.updateChangeCount(change)
        }
    }
}
