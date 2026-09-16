import AppKit
import Foundation
import CryptoKit
import FieldnotesCore

typealias DocumentByteWriter = (_ data: Data, _ destination: URL) throws -> Void

@objc(FieldnotesDocument)
final class FieldnotesDocument: NSDocument {
    let state: DocumentState
    private let byteWriter: DocumentByteWriter
    private var hasLoaded = false
    private var pendingExternalRead = false
    private var isClosed = false
    private var externalGeneration = 0
    private var activeSaveSnapshot: DocumentSaveSnapshot?
    private var protectedOriginal: (url: URL, data: Data?)?
    private var savedDigest: SHA256.Digest?
    private let externalChanges: ExternalChangeCoordinator

    nonisolated override class var autosavesInPlace: Bool { true }
    nonisolated override class var preservesVersions: Bool { true }

    nonisolated override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        false
    }

    override init() {
        state = DocumentState()
        externalChanges = ExternalChangeCoordinator()
        byteWriter = { data, destination in
            try data.write(to: destination, options: [])
        }
        super.init()
        connectChangeAccounting()
    }

    init(
        externalChanges: ExternalChangeCoordinator = ExternalChangeCoordinator(),
        byteWriter: @escaping DocumentByteWriter = { try $0.write(to: $1) }
    ) {
        state = DocumentState()
        self.byteWriter = byteWriter
        self.externalChanges = externalChanges
        super.init()
        connectChangeAccounting()
    }

    nonisolated override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        false
    }

    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try MainActor.assumeIsolated {
            if hasLoaded { try receiveExternal(data) }
            else {
                try state.replaceFromDisk(data)
                hasLoaded = true
            }
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
            try byteWriter(activeSaveSnapshot?.data ?? state.serializedData(), url)
            // Detect noncooperating writers that changed the original while temporary
            // output was produced. NSDocument will abandon that output on a thrown error.
            if let original = protectedOriginal, url.standardizedFileURL != original.url.standardizedFileURL {
                let current = try ExternalChangeCoordinator.diskData(at: original.url)
                if current != original.data {
                    try receiveExternal(current)
                    throw ExternalChangeError.unresolvedConflict
                }
            }
        }
    }

    nonisolated override func writeSafely(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) throws {
        dispatchPrecondition(condition: .onQueue(.main))
        try MainActor.assumeIsolated {
            // NSDocument owns the surrounding file coordination and atomic replacement.
            // This last check also catches notifications that have not reached the main actor yet.
            if url.standardizedFileURL == fileURL?.standardizedFileURL {
                guard state.conflict == nil else { throw ExternalChangeError.unresolvedConflict }
                let current = try ExternalChangeCoordinator.diskData(at: url)
                let expected: Data? = state.diskWasDeleted ? nil : state.baseData
                if current != expected {
                    try receiveExternal(current)
                    throw ExternalChangeError.unresolvedConflict
                }
                guard state.externalReadError == nil else { throw ExternalChangeError.unreadableDisk }
                protectedOriginal = (url, expected)
            }
            defer { protectedOriginal = nil }
            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        }
    }

    nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            await self?.reloadExternalChange()
        }
    }

    private func reloadExternalChange() async {
        guard !isClosed, let url = fileURL else { return }
        guard activeSaveSnapshot == nil else { pendingExternalRead = true; return }
        pendingExternalRead = false
        externalGeneration += 1
        let generation = externalGeneration
        do {
            let data = try await externalChanges.coordinatedRead(from: url, presenter: self)
            guard generation == externalGeneration, fileURL == url else { return }
            try receiveExternal(data)
        } catch {
            guard generation == externalGeneration, fileURL == url else { return }
            state.externalReadError = error.localizedDescription
        }
    }

    private func receiveExternal(_ data: Data?) throws {
        if let data, state.conflict == nil, state.externalReadError == nil,
           data == state.baseData, SHA256.hash(data: data) == savedDigest { return }
        let oldRevision = state.revision
        try state.acceptExternal(data)
        if state.conflict != nil, !isDocumentEdited { updateChangeCount(.changeDone) }
        else if state.revision != oldRevision, !state.hasUnsavedText, state.conflict == nil {
            updateChangeCount(.changeCleared)
            refreshDiskModificationDate()
        }
    }

    private func refreshDiskModificationDate() {
        fileModificationDate = fileURL.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard activeSaveSnapshot == nil else { completionHandler(ExternalChangeError.saveInProgress); return }
        if url.standardizedFileURL == fileURL?.standardizedFileURL {
            guard state.conflict == nil else { completionHandler(ExternalChangeError.unresolvedConflict); return }
            guard state.externalReadError == nil else { completionHandler(ExternalChangeError.unreadableDisk); return }
        }
        let snapshot: DocumentSaveSnapshot
        do {
            snapshot = try state.saveSnapshot()
        } catch {
            completionHandler(error)
            return
        }

        externalGeneration += 1
        activeSaveSnapshot = snapshot
        let finish: @MainActor @Sendable (Error?) -> Void = { [weak self] error in
            self?.activeSaveSnapshot = nil
            self?.externalGeneration += 1
            if error == nil, [.saveOperation, .saveAsOperation, .autosaveInPlaceOperation].contains(saveOperation) {
                self?.state.promoteSavedSnapshot(snapshot)
                self?.savedDigest = SHA256.hash(data: snapshot.data)
                if let self, self.state.hasUnsavedText || self.state.conflict != nil {
                    self.updateChangeCount(.changeDone)
                }
                for case let controller as DocumentWindowController in self?.windowControllers ?? [] {
                    try? controller.session.refreshDocumentLocation(url)
                    controller.workspaceURL = controller.session.currentWorkspaceURL
                }
            }
            if let self, self.pendingExternalRead {
                Task { @MainActor [weak self] in await self?.reloadExternalChange() }
            }
            completionHandler(error)
        }
        super.save(to: url, ofType: typeName, for: saveOperation) { @Sendable error in
            Task { @MainActor in finish(error) }
        }
    }

    func confirmConflict(_ review: ConflictReview) throws {
        guard activeSaveSnapshot == nil, let resolution = review.pending else { return }
        guard try state.resolveConflict(id: review.conflict.id, using: resolution) else { return }
        externalGeneration += 1
        refreshDiskModificationDate()
        updateChangeCount(.changeCleared)
        if state.hasUnsavedText { updateChangeCount(.changeDone) }
        review.cancel()
    }

    nonisolated override func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(nil); return }
            self.externalGeneration += 1
            do { try self.receiveExternal(nil); completionHandler(nil) }
            catch { completionHandler(error) }
        }
    }

    override func close() {
        isClosed = true
        externalGeneration += 1
        super.close()
    }

    override func makeWindowControllers() {
        let controller = DocumentWindowController(state: state)
        controller.onConfirmConflict = { [weak self] review in try self?.confirmConflict(review) }
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
        if Thread.isMainThread {
            MainActor.assumeIsolated { handleMove(to: newURL) }
        } else {
            Task { @MainActor [weak self] in self?.handleMove(to: newURL) }
        }
    }

    private func handleMove(to newURL: URL) {
        externalGeneration += 1
        super.presentedItemDidMove(to: newURL)
        for case let controller as DocumentWindowController in windowControllers {
            try? controller.session.refreshDocumentLocation(newURL)
            controller.workspaceURL = controller.session.currentWorkspaceURL
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
