import WebKit

@MainActor
final class WeakEditorReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var session: EditorSession?
    private(set) var isRegistered = true
    private var asynchronousTasks: [UUID: Task<Void, Never>] = [:]

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
            if request.kind == .workspaceSearch || request.kind == .imageImport || request.kind == .schemaValidate {
                guard asynchronousTasks.count < 8 else { replyHandler(nil, "too many pending requests"); return }
                let identifier = UUID()
                let task = Task { @MainActor [weak self, weak session] in
                    guard let session else { return }
                    let response: EditorSessionResponse
                    switch request.kind {
                    case .workspaceSearch: response = await session.prepareWorkspaceSearchResponse(to: request)
                    case .schemaValidate: response = await session.prepareSchemaValidationResponse(to: request)
                    default: response = await session.prepareImageImportResponse(to: request)
                    }
                    guard !Task.isCancelled, self?.isRegistered == true else { replyHandler(nil, "editor session unavailable"); self?.asynchronousTasks[identifier] = nil; return }
                    replyHandler(response.reply, nil)
                    self?.asynchronousTasks[identifier] = nil
                }
                asynchronousTasks[identifier] = task
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
        asynchronousTasks.values.forEach { $0.cancel() }
        asynchronousTasks.removeAll()
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
        #if FIELDNOTES_INTEGRATION
        configuration.userContentController.addUserScript(WKUserScript(source: "window.integrationErrors=[];window.addEventListener('securitypolicyviolation',e=>window.integrationErrors.push({directive:e.effectiveDirective,blocked:e.blockedURI}));window.addEventListener('error',e=>window.integrationErrors.push({message:e.message,source:e.filename,target:e.target?.src}),true);window.addEventListener('unhandledrejection',e=>window.integrationErrors.push(String(e.reason)));", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        #endif
        let handler = WeakEditorReplyHandler(session: session)
        let resourceHandler = ResourceSchemeHandler(resolver: ResourceResolver { [weak session] in session?.resourceScope })
        configuration.userContentController.addScriptMessageHandler(handler, contentWorld: .page, name: "native")
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "fieldnotes-resource")
        return EditorWebRegistration(configuration: configuration, handler: handler, resourceHandler: resourceHandler)
    }
}
