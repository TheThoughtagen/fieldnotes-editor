import WebKit

@MainActor
final class WeakEditorReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: EditorSession?
    private(set) var isRegistered = true

    init(session: EditorSession) {
        self.session = session
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard isRegistered, let session else {
            replyHandler(nil, "editor session unavailable")
            return
        }
        do {
            let request = try EditorBridgeRequest.validate(body: message.body, isMainFrame: message.frameInfo.isMainFrame)
            replyHandler(session.receive(request), nil)
        } catch {
            replyHandler(nil, "invalid editor message")
        }
    }

    func markRemoved() {
        isRegistered = false
        session = nil
    }
}

@MainActor
final class EditorWebRegistration {
    let configuration: WKWebViewConfiguration
    let handler: WeakEditorReplyHandler
    private var generation = UUID()

    init(configuration: WKWebViewConfiguration, handler: WeakEditorReplyHandler) {
        self.configuration = configuration
        self.handler = handler
    }

    var currentGeneration: UUID { generation }

    func teardown() {
        guard handler.isRegistered else { return }
        generation = UUID()
        configuration.userContentController.removeScriptMessageHandler(forName: "native", contentWorld: .page)
        handler.markRemoved()
    }

    deinit {
        MainActor.assumeIsolated { teardown() }
    }
}

enum EditorWebConfiguration {
    @MainActor
    static func make(session: EditorSession) -> EditorWebRegistration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let handler = WeakEditorReplyHandler(session: session)
        configuration.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "native")
        return EditorWebRegistration(configuration: configuration, handler: handler)
    }
}
