import SwiftUI
import FieldnotesCore

@main
struct FieldnotesApplication: App {
    @NSApplicationDelegateAdaptor(DocumentApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    do {
                        _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
                    } catch {
                        NSApplication.shared.presentError(error)
                    }
                }
                .keyboardShortcut("n")

                Button("Open…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o")
            }
            CommandMenu("Editor") {
                editorButton("Open Workspace File…", .openFile, key: "p")
                editorButton("Command Palette…", .commandPalette, key: "p", modifiers: [.command, .shift])
                editorButton("Search Workspace…", .searchWorkspace, key: "k")
                Divider()
                editorButton("Focus", .focus, key: "1")
                editorButton("Source", .source, key: "2")
                editorButton("Preview", .preview, key: "3")
                editorButton("Cycle Mode", .cycleMode, key: "\\")
                Divider()
                editorButton("Toggle Vim", .toggleVim, key: "v", modifiers: [.command, .shift])
            }
        }
    }

    private func editorButton(
        _ title: String,
        _ command: EditorCommand,
        key: KeyEquivalent,
        modifiers: EventModifiers = .command
    ) -> some View {
        Button(title) { activeSession()?.sendCommand?(command) }.keyboardShortcut(key, modifiers: modifiers)
    }

    private func activeSession() -> EditorSession? {
        (NSApplication.shared.keyWindow?.windowController as? DocumentWindowController)?.session
    }
}

@MainActor
final class DocumentApplicationDelegate: NSObject, NSApplicationDelegate {
    private let router = ApplicationOpenRouter()
    private lazy var requests = OpenRequestQueue { [weak self] request in self?.router.route(request) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        requests.applicationDidFinishLaunching()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            do {
                let request = url.isFileURL ? OpenRequest(target: url) : try OpenRequest(url: url)
                requests.enqueue(request)
            } catch {
                application.presentError(error)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        requests.shouldOpenUntitled
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        do {
            _ = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true)
            return true
        } catch {
            sender.presentError(error)
            return false
        }
    }
}
