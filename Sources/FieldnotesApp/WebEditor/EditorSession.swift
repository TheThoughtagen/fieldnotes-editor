import Foundation
import Observation
import FieldnotesCore

enum NativeEditorAction: String, Sendable { case save, quit }

enum SchemaStatus: String, Sendable {
    case unavailable = "Schema —", checking = "Schema checking", valid = "Schema valid", invalid = "Schema error"
}

enum EditorCommand: Sendable {
    case focus, source, preview, cycleMode, toggleVim, openFile, commandPalette, searchWorkspace
    var shortcut: Character { switch self { case .focus: "1"; case .source: "2"; case .preview: "3"; case .cycleMode: "\\"; case .toggleVim: "v"; case .openFile, .commandPalette: "p"; case .searchWorkspace: "k" } }
}

struct EditorOpenContext: Sendable {
    let context: WorkspaceContext
    let requestedMode: FieldnotesCore.PresentationMode?
    let line: Int?
    let column: Int?
}

struct EditorSessionResponse {
    let reply: [String: Any]
    let deferredAction: NativeEditorAction?
    let deferredOpenURL: URL?
    let deferredOpenLine: Int?
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
    private(set) var contextGeneration = 0
    private var pendingOpenContext: EditorOpenContext?
    private var contextAcknowledged = false
    private let defaults: UserDefaults
    var onContextChanged: (() -> Void)?
    private var workspaceIndex: WorkspaceIndex?
    private var indexTask: Task<WorkspaceIndex, Never>?
    private let indexBuilder: @Sendable (URL) -> WorkspaceIndex
    var onNativeAction: ((NativeEditorAction) -> Void)?
    var onOpenWorkspaceDocument: ((URL, Int?) -> Void)?
    var sendCommand: ((EditorCommand) -> Void)?
    var onEnsureSaveLocation: (() async -> URL?)?

    var resourceScope: ResourceScope? {
        guard let context = pendingOpenContext?.context else { return nil }
        let root: URL
        switch context.localAssetPolicy {
        case .workspace:
            root = context.workspace
        case .documentDirectory:
            guard let document = context.document else { return nil }
            root = document.deletingLastPathComponent()
        }
        let base = context.document?.deletingLastPathComponent() ?? root
        return ResourceScope(generation: contextGeneration, allowedRoot: root.resolvingSymlinksInPath().standardizedFileURL, baseURL: base.resolvingSymlinksInPath().standardizedFileURL)
    }

    var currentWorkspaceURL: URL? {
        pendingOpenContext?.context.workspace.resolvingSymlinksInPath().standardizedFileURL
    }

    var currentDocumentURL: URL? {
        pendingOpenContext?.context.document?.resolvingSymlinksInPath().standardizedFileURL
    }

    init(state: DocumentState, documentID: String = UUID().uuidString, defaults: UserDefaults = .standard, indexBuilder: @escaping @Sendable (URL) -> WorkspaceIndex = { WorkspaceIndex(root: $0) }) {
        self.state = state
        self.documentID = documentID
        self.defaults = defaults
        self.indexBuilder = indexBuilder
    }

    func installOpenContext(_ context: EditorOpenContext) {
        contextGeneration += 1
        pendingOpenContext = context
        contextAcknowledged = false
        switch context.context.schema {
        case .none: schemaStatus = .unavailable
        case .loaded: schemaStatus = .checking
        case .diagnostic: schemaStatus = .invalid
        }
        presentationMode = context.requestedMode?.rawValue ?? defaults.string(forKey: modeKey(context.context.workspace)) ?? "focus"
        indexTask?.cancel()
        workspaceIndex = nil
        let root = context.context.workspace, builder = indexBuilder
        indexTask = Task.detached(priority: .utility) { builder(root) }
        onContextChanged?()
    }

    func refreshDocumentLocation(_ url: URL) throws {
        let context = try WorkspaceResolver().resolve(input: url)
        installOpenContext(.init(context: context, requestedMode: FieldnotesCore.PresentationMode(rawValue: presentationMode), line: nil, column: nil))
    }

    func receive(_ request: EditorBridgeRequest) -> [String: Any] {
        prepareResponse(to: request).reply
    }

    func prepareResponse(to request: EditorBridgeRequest) -> EditorSessionResponse {
        if request.kind == .ready {
            guard request.documentID.isEmpty || request.documentID == documentID else { return response(rejection()) }
            return response(snapshot(consumingOpenContext: true))
        }
        guard request.documentID == documentID else { return response(rejection()) }

        switch request.kind {
        case .ready:
            return response(snapshot(consumingOpenContext: true))
        case .requestSnapshot:
            return response(snapshot())
        case .selection:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let selection = request.payload.selection
            else { return response(snapshot()) }
            state.updateSelection(.init(anchor: selection.anchor, head: selection.head))
            return response(acknowledgement())
        case .transaction:
            guard request.baseRevision == state.revision,
                  request.revision == request.baseRevision + 1,
                  let text = request.payload.text,
                  let selection = request.payload.selection,
                  let rawKind = request.payload.editKind,
                  let kind = editKind(rawKind)
            else { return response(snapshot()) }
            state.acceptEditorText(text, selection: .init(anchor: selection.anchor, head: selection.head), kind: kind)
            guard state.revision == request.revision else { return response(snapshot()) }
            return response(acknowledgement())
        case .status:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let mode = request.payload.presentationMode, let vim = request.payload.vimMode,
                  let line = request.payload.line, let column = request.payload.column,
                  let words = request.payload.wordCount,
                  validStatusPosition(line: line, column: column)
            else { return response(snapshot()) }
            if contextAcknowledged || pendingOpenContext == nil {
                presentationMode = mode
                if let root = pendingOpenContext?.context.workspace { defaults.set(mode, forKey: modeKey(root)) }
            }
            vimMode = vim
            self.line = line
            self.column = column
            wordCount = words
            return response(acknowledgement())
        case .action:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  let raw = request.payload.action, let action = NativeEditorAction(rawValue: raw)
            else { return response(snapshot()) }
            return response(acknowledgement(), deferredAction: action)
        case .schemaStatus:
            guard request.payload.generation == contextGeneration,
                  request.baseRevision == state.revision, request.revision == state.revision else { return response(rejection()) }
            switch request.payload.schemaState {
            case "valid": schemaStatus = .valid
            case "invalid": schemaStatus = .invalid
            default: schemaStatus = .unavailable
            }
            return response(acknowledgement())
        case .contextApplied:
            guard request.payload.generation == contextGeneration else { return response(rejection()) }
            contextAcknowledged = true
            return response(acknowledgement())
        case .workspaceSearch:
            // Search replies await background indexing through prepareWorkspaceSearchResponse.
            return response(rejection())
        case .workspaceOpen:
            guard request.baseRevision == state.revision, request.revision == state.revision,
                  request.payload.generation == contextGeneration,
                  let resultID = request.payload.resultID,
                  let url = workspaceIndex?.resolve(id: resultID)
            else { return response(rejection()) }
            return response(acknowledgement(), deferredOpenURL: url, deferredOpenLine: workspaceIndex?.line(id: resultID))
        case .imageImport:
            return response(rejection())
        }
    }

    func prepareWorkspaceSearchResponse(to request: EditorBridgeRequest) async -> EditorSessionResponse {
        guard request.kind == .workspaceSearch, request.documentID == documentID,
              request.payload.generation == contextGeneration, let query = request.payload.query,
              let indexTask else { return response(rejection()) }
        let generation = contextGeneration
        let index = await indexTask.value
        guard generation == contextGeneration else { return response(rejection()) }
        workspaceIndex = index
        let includeContent = request.payload.includeContent ?? false
        let results = await Task.detached(priority: .utility) { index.search(query, includeContent: includeContent) }.value
        guard generation == contextGeneration, request.baseRevision == state.revision,
              request.revision == state.revision else { return response(rejection()) }
        return response([
            "kind": "workspaceResults", "documentID": documentID,
            "revision": state.revision, "generation": generation,
            "results": results.map { ["id": $0.id, "title": $0.title] },
        ])
    }

    func prepareImageImportResponse(to request: EditorBridgeRequest) async -> EditorSessionResponse {
        guard request.kind == .imageImport, request.documentID == documentID,
              request.baseRevision == state.revision, request.revision == state.revision,
              request.payload.generation == contextGeneration else { return response(rejection()) }
        if pendingOpenContext?.context.document == nil {
            guard let savedURL = await onEnsureSaveLocation?() else {
                return response(["kind": "imageImportCancelled"])
            }
            do {
                if currentDocumentURL != savedURL.resolvingSymlinksInPath().standardizedFileURL {
                    try refreshDocumentLocation(savedURL)
                }
            }
            catch { return response(["kind": "imageImportFailed", "reason": "save location unavailable"]) }
        }
        do { return response(try importImage(request.payload)) }
        catch { return response(["kind": "imageImportFailed", "reason": String(describing: error)]) }
    }

    func perform(_ action: NativeEditorAction) {
        onNativeAction?(action)
    }

    func openWorkspaceDocument(_ url: URL, line: Int? = nil) {
        onOpenWorkspaceDocument?(url, line)
    }

    func snapshot(consumingOpenContext: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "kind": "snapshot",
            "documentID": documentID,
            "revision": state.revision,
            "text": state.editorText,
            "selection": ["anchor": state.selection.anchor, "head": state.selection.head],
        ]
        if let pendingOpenContext {
            value["openContext"] = serialized(pendingOpenContext)
        }
        return value
    }

    private func serialized(_ open: EditorOpenContext) -> [String: Any] {
        var diagnostics = open.context.diagnostics
        if case .diagnostic(let message) = open.context.schema { diagnostics.append(message) }
        let lines = state.editorText.split(separator: "\n", omittingEmptySubsequences: false)
        let requestedLine = open.line ?? 1
        let line = min(max(requestedLine, 1), max(lines.count, 1))
        let lineWasClamped = line != requestedLine
        let requestedColumn = open.column ?? 1
        let maximumColumn = (lines.indices.contains(line - 1) ? lines[line - 1].utf16.count : 0) + 1
        let column = min(max(requestedColumn, 1), maximumColumn)
        if lineWasClamped || column != requestedColumn {
            diagnostics.append("Requested position was clamped to the document")
        }
        var value: [String: Any] = [
            "generation": contextGeneration,
            "workspaceName": open.context.workspace.lastPathComponent,
            "documentName": open.context.document?.lastPathComponent ?? NSNull(),
            "assetPolicy": open.context.localAssetPolicy.rawValue,
            "mode": presentationMode,
            "line": !contextAcknowledged && open.line != nil ? line : NSNull(),
            "column": !contextAcknowledged && open.line != nil ? column : NSNull(),
            "diagnostics": diagnostics,
            "schema": NSNull(),
        ]
        if case .loaded(_, let data) = open.context.schema {
            value["schema"] = try? JSONSerialization.jsonObject(with: data)
        }
        return value
    }

    private func modeKey(_ root: URL) -> String {
        "workspaceMode." + root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func importImage(_ payload: EditorBridgePayload) throws -> [String: Any] {
        guard let context = pendingOpenContext?.context, let document = context.document,
              let filename = payload.filename, let altText = payload.altText else {
            return ["kind": "imageSaveRequired"]
        }
        let documentDirectory = document.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let destination: URL
        if payload.linkInPlace == true {
            guard let source = payload.sourceURL.flatMap(URL.init(string:)) else { throw ResourceError.malformedRequest }
            destination = source.resolvingSymlinksInPath().standardizedFileURL
            let allowedRoot = resourceScope?.allowedRoot ?? documentDirectory
            guard contains(destination, in: allowedRoot),
                  (try? destination.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw ResourceError.outsideAllowedRoot
            }
        } else {
            let images = documentDirectory.appendingPathComponent("images", isDirectory: true)
            if let encoded = payload.dataBase64, let data = Data(base64Encoded: encoded), data.count <= 20_000_000 {
                destination = try ImageImporter().write(data, suggestedName: filename, into: images)
            } else if let source = payload.sourceURL.flatMap(URL.init(string:)) {
                destination = try ImageImporter().copy(source, into: images)
            } else { throw ResourceError.malformedRequest }
        }
        let relative = relativePath(from: documentDirectory, to: destination)
        let escapedAlt = altText.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
        var reply: [String: Any] = ["kind": "imageImported", "path": relative, "altText": escapedAlt]
        if payload.linkInPlace == true, context.localAssetPolicy == .documentDirectory {
            reply["diagnostic"] = "Linked image remains in place; publication requires assets inside the post directory."
        }
        return reply
    }

    private func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootParts = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidateParts = candidate.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidateParts.count >= rootParts.count && Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    private func relativePath(from base: URL, to target: URL) -> String {
        let baseParts = base.standardizedFileURL.pathComponents
        let targetParts = target.standardizedFileURL.pathComponents
        var common = 0
        while common < min(baseParts.count, targetParts.count), baseParts[common] == targetParts[common] { common += 1 }
        let components = Array(repeating: "..", count: baseParts.count - common) + targetParts.dropFirst(common)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "()"))
        return components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }.joined(separator: "/")
    }

    private func acknowledgement() -> [String: Any] {
        ["kind": "ack", "documentID": documentID, "revision": state.revision]
    }

    private func rejection() -> [String: Any] {
        ["kind": "rejected", "reason": "document"]
    }

    private func response(
        _ reply: [String: Any],
        deferredAction: NativeEditorAction? = nil,
        deferredOpenURL: URL? = nil,
        deferredOpenLine: Int? = nil
    ) -> EditorSessionResponse {
        EditorSessionResponse(reply: reply, deferredAction: deferredAction, deferredOpenURL: deferredOpenURL, deferredOpenLine: deferredOpenLine)
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
