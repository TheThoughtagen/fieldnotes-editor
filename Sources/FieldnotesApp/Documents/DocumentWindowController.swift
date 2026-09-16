import AppKit
import SwiftUI
import FieldnotesCore

@MainActor
final class DocumentWindowController: NSWindowController {
    let state: DocumentState
    let session: EditorSession
    var workspaceURL: URL?

    init(state: DocumentState) {
        self.state = state
        session = EditorSession(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 640, height: 420)
        window.contentViewController = NSHostingController(rootView: DocumentView(state: state, session: session))
        window.setFrame(
            NSRect(origin: window.frame.origin, size: NSSize(width: 960, height: 720)),
            display: false
        )
        window.center()
        super.init(window: window)
        session.onNativeAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .save: (self.document as? NSDocument)?.save(nil)
            case .quit: self.window?.performClose(nil)
            }
        }
        session.onOpenWorkspaceDocument = { [weak self] url, line in
            ApplicationOpenRouter().route(OpenRequest(target: url, line: line), workspaceRoot: self?.workspaceURL)
        }
        session.onEnsureSaveLocation = { [weak self] in
            guard let self, let document = self.document as? NSDocument else { return nil }
            if let fileURL = document.fileURL { return fileURL }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Untitled.md"
            let result: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
                if let window = self.window {
                    panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                } else {
                    continuation.resume(returning: panel.runModal())
                }
            }
            guard result == .OK, let url = panel.url else { return nil }
            let error: Error? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: document.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation) {
                    continuation.resume(returning: $0)
                }
            }
            guard error == nil else { return nil }
            return document.fileURL ?? url
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }
}
