import SwiftUI

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
private final class DocumentApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
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
