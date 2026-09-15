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
        }
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
