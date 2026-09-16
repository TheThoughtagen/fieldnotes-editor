import AppKit
import SwiftUI
import WebKit

enum EditorNavigationDecision: Equatable {
    case allow
    case openExternally
    case cancel
}

enum EditorNavigationPolicy {
    static func decide(url: URL, editorRoot: URL, isUserLink: Bool) -> EditorNavigationDecision {
        let index = editorRoot.appendingPathComponent("index.html").standardizedFileURL
        if url.isFileURL, url.standardizedFileURL == index { return .allow }
        if isUserLink, url.scheme?.lowercased() == "https" { return .openExternally }
        return .cancel
    }
}

struct WebEditorView: NSViewRepresentable {
    let session: EditorSession
    let revision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        let webView = WKWebView(frame: .zero, configuration: coordinator.registration.configuration)
        coordinator.attach(webView)
        if let indexURL = Self.editorIndexURL() {
            coordinator.editorRoot = indexURL.deletingLastPathComponent()
            webView.loadFileURL(indexURL, allowingReadAccessTo: coordinator.editorRoot!)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.pushSnapshotIfNeeded(revision: revision)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown(webView)
    }

    private static func editorIndexURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("editor-web", isDirectory: true)
            .appendingPathComponent("index.html", isDirectory: false)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: EditorSession
        let registration: EditorWebRegistration
        weak var webView: WKWebView?
        var editorRoot: URL?
        private var lastPushedRevision = -1
        let themeStore: ThemeStore
        private var themeRevision = 0

        init(session: EditorSession, themeStore: ThemeStore = .shared) {
            self.session = session
            self.themeStore = themeStore
            registration = EditorWebConfiguration.make(session: session)
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: ThemeStore.changed, object: themeStore)
            webView.navigationDelegate = self
            webView.uiDelegate = self
            session.onContextChanged = { [weak self] in self?.pushSnapshotIfNeeded(revision: self?.session.state.revision ?? 0, force: true) }
            session.sendCommand = { [weak self] command in self?.send(command) }
        }

        /// Only normalized data crosses this boundary; no theme-controlled script or CSS text.
        @objc func themeChanged() {
            guard let webView else { return }
            themeRevision += 1
            let revision = themeRevision
            let theme = themeStore.effectiveTheme
            let arguments: [String: Any] = ["tokens": theme?.tokens ?? [:], "keys": Array(ThemeCatalog.keys), "kind": theme?.kind.rawValue ?? "", "id": themeStore.effectiveID, "revision": revision]
            Task { @MainActor [weak webView] in
                _ = try? await webView?.callAsyncJavaScript("""
                    if ((window.fieldnotesThemeRevision || 0) > revision) return false;
                    window.fieldnotesThemeRevision = revision;
                    const root = document.documentElement;
                    for (const key of keys) {
                        const color = tokens[key];
                        if (typeof color === 'string' && /^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(color)) root.style.setProperty('--fn-' + key, color);
                        else root.style.removeProperty('--fn-' + key);
                    }
                    if (kind === 'light' || kind === 'dark') root.style.colorScheme = kind;
                    else root.style.removeProperty('color-scheme');
                    root.dataset.theme = id;
                    return true;
                    """, arguments: arguments, in: nil, contentWorld: .page)
            }
        }

        func pushSnapshotIfNeeded(revision: Int, force: Bool = false, attempt: Int = 0) {
            guard force || revision != lastPushedRevision, let webView else { return }
            lastPushedRevision = revision
            let generation = registration.currentGeneration
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                let accepted = try? await webView.callAsyncJavaScript(
                    "return window.fieldnotes.applyNativeSnapshot(snapshot)",
                    arguments: ["snapshot": self.session.snapshot()],
                    in: nil,
                    contentWorld: .page
                )
                guard self.registration.currentGeneration == generation else { return }
                if accepted as? Bool != true {
                    self.lastPushedRevision = -1
                    if attempt < 10 {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard self.registration.currentGeneration == generation else { return }
                        self.pushSnapshotIfNeeded(revision: self.session.state.revision, force: true, attempt: attempt + 1)
                    }
                }
            }
        }

        func teardown(_ webView: WKWebView) {
            NotificationCenter.default.removeObserver(self, name: ThemeStore.changed, object: themeStore)
            session.onContextChanged = nil
            session.sendCommand = nil
            session.onEnsureSaveLocation = nil
            session.onChooseLinkInPlaceImage = nil
            Task { @MainActor [weak webView] in
                _ = try? await webView?.callAsyncJavaScript("window.fieldnotes.destroy()", arguments: [:], in: nil, contentWorld: .page)
            }
            registration.teardown()
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            self.webView = nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable (String?) -> Void
        ) {
            guard frame.isMainFrame, prompt == "Describe this image for readers", let window = webView.window else {
                completionHandler(nil)
                return
            }
            let alert = NSAlert()
            alert.messageText = "Image description"
            alert.informativeText = "Describe the image for readers who cannot see it."
            alert.addButton(withTitle: "Insert")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.placeholderString = "Meaningful alt text"
            field.frame.size = NSSize(width: 320, height: 24)
            alert.accessoryView = field
            alert.beginSheetModal(for: window) { response in
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                completionHandler(response == .alertFirstButtonReturn && !text.isEmpty ? text : nil)
            }
        }

        private func send(_ command: EditorCommand) {
            guard let webView else { return }
            let script: String
            let arguments: [String: Any]
            switch command {
            case .focus, .source, .preview:
                script = "return window.fieldnotes.setMode(mode)"
                arguments = ["mode": String(describing: command)]
            case .cycleMode:
                script = "window.fieldnotes.cycleMode()"
                arguments = [:]
            case .openFile, .commandPalette, .searchWorkspace:
                script = "window.dispatchEvent(new KeyboardEvent('keydown', {key: key, metaKey: true, shiftKey: shift}))"
                arguments = ["key": String(command.shortcut), "shift": command == .commandPalette]
            case .toggleVim:
                script = "window.fieldnotes.toggleVim()"
                arguments = [:]
            }
            Task { @MainActor [weak webView] in
                _ = try? await webView?.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            themeChanged()
            pushSnapshotIfNeeded(revision: session.state.revision, force: true)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            guard let editorRoot else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame == false, session.remoteImagesEnabled,
               url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
               (url.host == "www.youtube-nocookie.com" && url.path.hasPrefix("/embed/") ||
                url.host == "player.vimeo.com" && url.path.hasPrefix("/video/")) {
                decisionHandler(.allow)
                return
            }
            switch EditorNavigationPolicy.decide(
                url: url,
                editorRoot: editorRoot,
                isUserLink: navigationAction.navigationType == .linkActivated
            ) {
            case .allow:
                decisionHandler(.allow)
            case .openExternally:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               navigationAction.navigationType == .linkActivated,
               navigationAction.request.url?.scheme?.lowercased() == "https",
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }
}
