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
        handle(body: message.body, isMainFrame: message.frameInfo.isMainFrame, replyHandler: replyHandler)
    }

    func handle(
        body: Any,
        isMainFrame: Bool,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard isRegistered, let session else {
            replyHandler(nil, "editor session unavailable")
            return
        }
        do {
            let request = try EditorBridgeRequest.validate(body: body, isMainFrame: isMainFrame)
            if request.kind == .workspaceSearch || request.kind == .imageImport {
                Task { @MainActor [weak self, session] in
                    let response = request.kind == .workspaceSearch
                        ? await session.prepareWorkspaceSearchResponse(to: request)
                        : await session.prepareImageImportResponse(to: request)
                    guard self?.isRegistered == true else { replyHandler(nil, "editor session unavailable"); return }
                    replyHandler(response.reply, nil)
                }
                return
            }
            let response = session.prepareResponse(to: request)
            replyHandler(response.reply, nil)
            if let action = response.deferredAction {
                Task { @MainActor [session] in
                    await Task.yield()
                    session.perform(action)
                }
            }
            if let url = response.deferredOpenURL {
                Task { @MainActor [session] in
                    await Task.yield()
                    session.openWorkspaceDocument(url, line: response.deferredOpenLine)
                }
            }
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
    let resourceHandler: ResourceSchemeHandler?
    private var generation = UUID()

    init(configuration: WKWebViewConfiguration, handler: WeakEditorReplyHandler, resourceHandler: ResourceSchemeHandler? = nil) {
        self.configuration = configuration
        self.handler = handler
        self.resourceHandler = resourceHandler
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
        let resourceHandler = ResourceSchemeHandler(resolver: ResourceResolver { [weak session] in session?.resourceScope })
        configuration.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "native")
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "fieldnotes-resource")
        return EditorWebRegistration(configuration: configuration, handler: handler, resourceHandler: resourceHandler)
    }
}
