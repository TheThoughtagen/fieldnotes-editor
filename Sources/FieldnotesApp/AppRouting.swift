import AppKit
import FieldnotesCore
import Foundation

@MainActor
final class OpenRequestQueue {
    private var pending: [OpenRequest] = []
    private var didFinishLaunching = false
    private let open: (OpenRequest) -> Void

    init(open: @escaping (OpenRequest) -> Void) {
        self.open = open
    }

    var shouldOpenUntitled: Bool { pending.isEmpty }

    func enqueue(_ request: OpenRequest) {
        guard didFinishLaunching else {
            pending.append(request)
            return
        }
        open(request)
    }

    func applicationDidFinishLaunching() {
        guard !didFinishLaunching else { return }
        didFinishLaunching = true
        let queued = pending
        pending.removeAll(keepingCapacity: false)
        queued.forEach(open)
    }
}

enum CanonicalDocumentLookup {
    static func matching(_ target: URL, in candidates: [URL]) -> URL? {
        let canonical = target.resolvingSymlinksInPath().standardizedFileURL
        return candidates.first { $0.resolvingSymlinksInPath().standardizedFileURL == canonical }
    }
}

@MainActor
final class ApplicationOpenRouter {
    private let controller: NSDocumentController
    private let resolver = WorkspaceResolver()

    init(controller: NSDocumentController = .shared) {
        self.controller = controller
    }

    func route(_ request: OpenRequest, workspaceRoot: URL? = nil) {
        do {
            let context = try resolver.resolve(input: request.target, explicitSchema: request.schema, workspaceRoot: workspaceRoot)
            if let documentURL = context.document {
                openDocument(documentURL, context: context, request: request)
            } else {
                openWorkspace(context, request: request)
            }
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    private func openDocument(_ url: URL, context: WorkspaceContext, request: OpenRequest) {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = controller.documents.first(where: {
            guard let fileURL = $0.fileURL else { return false }
            return fileURL.resolvingSymlinksInPath().standardizedFileURL == canonical
        }) {
            install(context, request: request, on: existing)
            existing.showWindows()
            return
        }
        controller.openDocument(withContentsOf: canonical, display: true) { [self] document, _, error in
            if let error { NSApplication.shared.presentError(error); return }
            if let document { self.install(context, request: request, on: document) }
        }
    }

    private func openWorkspace(_ context: WorkspaceContext, request: OpenRequest) {
        let canonical = context.workspace.resolvingSymlinksInPath().standardizedFileURL
        if let existing = controller.documents
            .flatMap(\.windowControllers)
            .compactMap({ $0 as? DocumentWindowController })
            .first(where: { $0.workspaceURL == canonical && ($0.document as? NSDocument)?.fileURL == nil }) {
            if let document = existing.document as? NSDocument { install(context, request: request, on: document) }
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let document = try controller.openUntitledDocumentAndDisplay(false)
            install(context, request: request, on: document)
            document.showWindows()
        } catch {
            NSApplication.shared.presentError(error)
        }
    }

    private func install(_ context: WorkspaceContext, request: OpenRequest, on document: NSDocument) {
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        for case let window as DocumentWindowController in document.windowControllers {
            window.workspaceURL = context.workspace.resolvingSymlinksInPath().standardizedFileURL
            window.session.installOpenContext(.init(
                context: context,
                requestedMode: request.mode,
                line: request.line,
                column: request.column
            ))
        }
    }
}
