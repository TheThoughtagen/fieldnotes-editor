import AppKit
import Testing
import WebKit
@testable import FieldnotesApp

@Suite("Theme catalog and safe import", .serialized)
@MainActor struct ThemeTests {
    @Test func jsoncImport() throws {
        let theme = try ThemeImporter.parse(Data("""
        { // exported theme
          "name": "A // theme", "type": "dark", "colors": {"editor.background":"#112233",},
          "tokenColors": [{"scope":["keyword.control", "storage.type"],"settings":{"foreground":"#abcdef"}},],
        }
        """.utf8))
        #expect(theme.name == "A // theme")
        #expect(theme.tokens["paper"] == "#112233")
        #expect(theme.tokens["purple"] == "#abcdef")
        #expect(theme.kind == .dark)
    }
    @Test func rejectsUnsafeAndMalformed() {
        for source in ["{\"include\":\"../other.json\"}", "{\"name\":\"Bad\",\"colors\":{\"editor.background\":\"url(https://evil)\"}}", "{\"name\":\"Bad\",\"tokenColors\":\"./tokens.json\"}", "{ /* unfinished", "{\"name\":\"Bad\",\"type\":\"wrong\"}"] {
            #expect(throws: (any Error).self) { try ThemeImporter.parse(Data(source.utf8)) }
        }
        #expect(throws: (any Error).self) { try ThemeImporter.parse(Data(repeating: 32, count: 1_048_577)) }
    }
    @Test func catalogPreviewPersistenceAndRemoval() throws {
        let name = "ThemeTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: name))
        let original = NSApplication.shared.appearance
        defer { defaults.removePersistentDomain(forName: name); NSApplication.shared.appearance = original }
        let store = ThemeStore(defaults: defaults)
        #expect(store.catalog.count >= 6)
        store.select(id: "midnight")
        store.beginPreview(); store.preview(id: "linen")
        #expect(store.effectiveID == "linen")
        #expect(ThemeStore(defaults: defaults).selectedID == "midnight")
        store.cancelPreview()
        #expect(store.effectiveID == "midnight")
        store.beginPreview(); store.preview(id: "forest"); store.commitPreview()
        #expect(ThemeStore(defaults: defaults).selectedID == "forest")
        let imported = try store.importData(Data("{\"name\":\"Mine\",\"type\":\"light\"}".utf8))
        #expect(ThemeStore(defaults: defaults).catalog.contains { $0.id == imported.id })
        store.select(id: imported.id); store.remove(id: imported.id)
        #expect(store.selectedID == "system")
        store.remove(id: "linen")
        #expect(store.catalog.contains { $0.id == "linen" })
        store.select(id: "unknown")
        #expect(store.selectedID == "system")
    }
}

@Suite("Shipping editor themes in native WebKit", .serialized)
@MainActor struct NativeThemeTests {
    @Test func liveShippingEditor() async throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = ProcessInfo.processInfo.environment["FIELDNOTES_THEME_ASSETS"].map { URL(fileURLWithPath: $0) } ?? repo.appendingPathComponent("build/editor-web")
        let index = root.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: index.path) else { throw ThemeImportError.invalid("Run npm run build before native shipping-asset tests.") }
        let suite = "NativeThemeTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let store = ThemeStore(defaults: defaults), original = NSApplication.shared.appearance
        var windows: [NSWindow] = [], coordinators: [WebEditorView.Coordinator] = [], webs: [WKWebView] = []
        defer {
            for (coordinator, web) in zip(coordinators, webs) { coordinator.teardown(web) }
            windows.forEach { $0.orderOut(nil); $0.contentView = nil }
            NSApplication.shared.appearance = original; defaults.removePersistentDomain(forName: suite)
        }
        let source = "---\ntitle: Native theme proof\n---\n\n# Native heading\n\n## Second heading\n\nSetext heading\n===\n\n" + String(repeating: "A long document with **strong** text and `code`.\n\n", count: 150)
        for number in 0..<2 {
            let state = try DocumentState(data: Data(source.utf8)), session = EditorSession(state: state, defaults: defaults)
            let coordinator = WebEditorView.Coordinator(session: session, themeStore: store)
            let window = NSWindow(contentRect: NSRect(x: 80 + number * 60, y: 80, width: 950, height: 780), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "FIELDNOTES native theme UAT \(number + 1)"; window.isReleasedWhenClosed = false
            let web = WKWebView(frame: window.contentView!.bounds, configuration: coordinator.registration.configuration)
            coordinator.attach(web); coordinator.editorRoot = root; window.contentView = web
            windows.append(window); coordinators.append(coordinator); webs.append(web)
            web.loadFileURL(index, allowingReadAccessTo: root); window.orderFront(nil)
            try await eventually(web, "document.querySelector('#editor')?.fieldnotesEditor?.view.state.doc.length === \(source.utf16.count)")
            _ = try await web.evaluateJavaScript("""
                window.uatEditor = document.querySelector('#editor').fieldnotesEditor;
                window.uatView = uatEditor.view;
                uatView.dispatch({changes:{from:uatView.state.doc.length,insert:'Retained edit 🧭'},selection:{anchor:8}});
                window.uatState = uatView.state;
                window.uatVim = uatEditor.vimEnabled;
                true;
                """)
        }
        for id in ["midnight", "linen", "forest", "ink", "glacier", "sandstone"] {
            store.select(id: id)
            for web in webs {
                try await eventually(web, "document.documentElement.dataset.theme === '\(id)' && uatEditor.view === uatView && uatView.state === uatState && uatEditor.vimEnabled === uatVim")
                let theme = try #require(store.effectiveTheme)
                let actual = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--fn-paper').trim()") as? String
                #expect(actual == theme.tokens["paper"])
                #expect(web.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (theme.kind == .dark ? .darkAqua : .aqua))
            }
        }
        store.select(id: "midnight")
        let web = webs[0]
        _ = try await web.evaluateJavaScript("window.fieldnotes.setMode('source'); uatView.scrollDOM.scrollTop = 400; window.uatState = uatView.state; true")
        try await Task.sleep(for: .milliseconds(250))
        _ = try await web.evaluateJavaScript("uatView.scrollDOM.scrollTop = 400; window.uatState = uatView.state; true")
        try await eventually(web, "uatView.scrollDOM.scrollTop === 400")
        store.beginPreview(); store.preview(id: "linen")
        try await eventually(web, "document.documentElement.dataset.theme === 'linen' && uatView.state === uatState && uatView.scrollDOM.scrollTop === 400")
        #expect(ThemeStore(defaults: defaults).selectedID == "midnight")
        store.cancelPreview()
        try await eventually(web, "document.documentElement.dataset.theme === 'midnight' && uatView.state === uatState && uatView.scrollDOM.scrollTop === 400")
        let gutter = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.cm-gutters')).backgroundColor") as? String
        #expect(gutter == "rgb(32, 35, 38)")
        _ = try await web.evaluateJavaScript("window.fieldnotes.setMode('focus'); uatView.scrollDOM.scrollTop = 0; true")
        try await eventually(web, "document.querySelector('.fn-atxheading1') !== null && document.querySelector('.fn-setextheading1') !== null")
        let proof = try await web.evaluateJavaScript("""
            JSON.stringify({theme:document.documentElement.dataset.theme,
            heading:getComputedStyle(document.querySelector('.fn-atxheading1')).fontSize,
            second:getComputedStyle(document.querySelector('.fn-atxheading2')).fontSize,
            setext:getComputedStyle(document.querySelector('.fn-setextheading1')).fontSize,
            metadata:getComputedStyle(document.querySelector('.fn-frontmatter-line')).fontSize,
            gutter:document.querySelector('.cm-gutters') ? getComputedStyle(document.querySelector('.cm-gutters')).display : 'absent',
            unchanged:uatView.state.doc.toString().endsWith('Retained edit 🧭') && uatView.state.selection.main.head === 8})
            """) as? String
        let data = try #require(proof?.data(using: .utf8)), result = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(abs(Double((result["heading"] as? String ?? "").replacingOccurrences(of: "px", with: ""))! - 28.8) < 0.001)
        #expect(result["second"] as? String == "24px")
        #expect(abs(Double((result["setext"] as? String ?? "").replacingOccurrences(of: "px", with: ""))! - 28.8) < 0.001)
        #expect(result["metadata"] as? String == "13px")
        #expect(["none", "absent"].contains(result["gutter"] as? String ?? ""))
        #expect(result["unchanged"] as? Bool == true)
        #expect(coordinators[0].session.state.editorText == source + "Retained edit 🧭")
        let future = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        future.isReleasedWhenClosed = false; windows.append(future)
        #expect(future.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let futureCoordinator = WebEditorView.Coordinator(session: EditorSession(state: DocumentState(), defaults: defaults), themeStore: store)
        let futureWeb = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: futureCoordinator.registration.configuration)
        futureCoordinator.attach(futureWeb); futureCoordinator.editorRoot = root; future.contentView = futureWeb
        webs.append(futureWeb); coordinators.append(futureCoordinator)
        futureWeb.loadFileURL(index, allowingReadAccessTo: root)
        try await eventually(futureWeb, "document.documentElement.dataset.theme === 'midnight'")
        if let output = ProcessInfo.processInfo.environment["FIELDNOTES_THEME_EVIDENCE"] {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("theme-system-native-measurements.json"))
            let image = try await web.takeSnapshot(configuration: nil)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("theme-system-native-focus.png"))
            }

        }
        store.select(id: "system")
        try await eventually(web, "document.documentElement.dataset.theme === 'system' && document.documentElement.style.getPropertyValue('--fn-paper') === ''")
        #expect(NSApplication.shared.appearance == nil)
    }
    @Test func nativePickerKeyboard() async throws {
        let suite = "NativePickerTests.\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        let store = ThemeStore(defaults: defaults), original = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = original; defaults.removePersistentDomain(forName: suite) }
        store.select(id: "midnight")
        let picker = ThemePickerController(store: store)
        picker.show()
        let panel = try #require(NSApplication.shared.windows.compactMap { $0 as? ThemePickerPanel }.first { $0.isVisible })
        defer { panel.performClose(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let search = try #require(descendants(panel.contentView!).compactMap { $0 as? NSSearchField }.first)
        let table = try #require(descendants(panel.contentView!).compactMap { $0 as? NSTableView }.first)
        func key(_ code: UInt16, _ characters: String) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            panel.sendEvent(event)
        }
        #expect(table.numberOfRows == 7)
        try key(125, "\u{f701}")
        #expect(store.effectiveID == "sandstone")
        #expect(store.selectedID == "midnight")
        try key(53, "\u{1b}")
        #expect(store.effectiveID == "midnight")
        #expect(!panel.isVisible)
        picker.show()
        let secondPanel = try #require(NSApplication.shared.windows.compactMap { $0 as? ThemePickerPanel }.first { $0.isVisible })
        // Native field-editor insertion drives NSSearchFieldDelegate filtering.
        search.selectText(nil)
        let fieldEditor = try #require(search.currentEditor() as? NSTextView)
        fieldEditor.insertText("forest", replacementRange: NSRange(location: 0, length: fieldEditor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(150))
        #expect(table.numberOfRows == 1)
        #expect(store.effectiveID == "forest")
        #expect(store.selectedID == "midnight")
        if let output = ProcessInfo.processInfo.environment["FIELDNOTES_THEME_EVIDENCE"] {
            let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(secondPanel.windowNumber), URL(fileURLWithPath: output).appendingPathComponent("theme-system-native-picker.png").path]
            try capture.run(); capture.waitUntilExit()
        }
        let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: secondPanel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        secondPanel.sendEvent(enter)
        #expect(store.selectedID == "forest")
        #expect(!secondPanel.isVisible)
        #expect(ThemeStore(defaults: defaults).selectedID == "forest")
    }

    private func eventually(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<150 {
            if let result = try? await web.evaluateJavaScript(script), result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        let details = try? await web.evaluateJavaScript("JSON.stringify({theme:document.documentElement.dataset.theme,scroll:window.uatView?.scrollDOM.scrollTop,state:window.uatView?.state === window.uatState})")
        throw ThemeImportError.invalid("Native WK condition failed: \(script); \(details ?? "unknown")")
    }
}
