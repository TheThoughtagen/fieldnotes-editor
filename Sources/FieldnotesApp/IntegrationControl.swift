#if FIELDNOTES_INTEGRATION
// Compiled only by scripts/test-app-integration.sh. No command transport exists in release builds.
import AppKit
import WebKit

@MainActor
enum IntegrationControl {
    static var firstSaveResult = ""
    static weak var activeDocument: FieldnotesDocument?
    static func start() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("integration"),
              FileManager.default.fileExists(atPath: directory.path) else { return }
        try? String(ProcessInfo.processInfo.processIdentifier).write(to: directory.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        Task { @MainActor in
            while !Task.isCancelled {
                let requestURL = directory.appendingPathComponent("request.json")
                if let data = try? Data(contentsOf: requestURL),
                   let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    try? FileManager.default.removeItem(at: requestURL)
                    var reply: [String: Any]
                    do { reply = try await perform(request) }
                    catch { reply = ["error": String(describing: error)] }
                    reply["id"] = request["id"]
                    if let bytes = try? JSONSerialization.data(withJSONObject: reply) {
                        try? bytes.write(to: directory.appendingPathComponent("response.json"), options: .atomic)
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    static func webView(_ view: NSView?) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view?.subviews.compactMap { webView($0) }.first
    }
    static func perform(_ request: [String: Any]) async throws -> [String: Any] {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? FieldnotesDocument }
        if request["action"] as? String == "new" {
            activeDocument = try NSDocumentController.shared.openUntitledDocumentAndDisplay(true) as? FieldnotesDocument
        }
        guard let document = activeDocument ?? documents.first,
              let controller = document.windowControllers.first as? DocumentWindowController,
              let web = webView(controller.window?.contentView) else { return ["count": documents.count] }
        let action = request["action"] as? String
        var themeProof: [String: Any]?
        switch action {
        case "firstSave":
            firstSaveResult = "pending"
            Task { @MainActor in firstSaveResult = await controller.session.onEnsureSaveLocation?()?.path ?? "cancelled" }
        case "cancelSave":
            (controller.window?.attachedSheet as? NSSavePanel)?.cancel(nil)
        case "acceptNextFirstSave":
            guard let path = request["path"] as? String else { throw CocoaError(.fileNoSuchFile) }
            let url = URL(fileURLWithPath: path)
            // The OS remote Save button cannot be driven without accessibility permission.
            // Inject only the chosen location; exercise the real first-save transition and write.
            controller.session.onEnsureSaveLocation = { [weak controller, weak document] in
                guard let controller, let document else { return nil }
                controller.session.authorizeFirstSaveTransition(to: url)
                let error: Error? = await withCheckedContinuation { continuation in
                    document.save(to: url, ofType: document.fileType ?? "net.daringfireball.markdown", for: .saveAsOperation) { continuation.resume(returning: $0) }
                }
                if error != nil { controller.session.cancelFirstSaveTransition(); return nil }
                firstSaveResult = document.fileURL?.path ?? url.path
                return document.fileURL ?? url
            }
        case "source": controller.session.sendCommand?(.source)
        case "theme": ThemeStore.shared.select(id: request["theme"] as? String ?? "system")
        case "themeMeasure":
            controller.window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            themeProof = try await web.callAsyncJavaScript("""
                await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                const e = document.querySelector('#editor').fieldnotesEditor, v = e.view;
                const rows = [...document.querySelectorAll('.cm-lineNumbers .cm-gutterElement')].filter(e => getComputedStyle(e).visibility !== 'hidden').slice(0,12).map(e => {
                    const n=Number(e.textContent), node=v.domAtPos(v.state.doc.line(n).from).node;
                    const line=(node.nodeType===1?node:node.parentElement).closest('.cm-line');
                    return {n,gutter:e.getBoundingClientRect().top,line:line?.getBoundingClientRect().top};
                });
                const heading = document.querySelector('.fn-atxheading1');
                return {theme:document.documentElement.dataset.theme,rows,heading:heading?getComputedStyle(heading).fontSize:'',gutter:document.querySelector('.cm-gutters')?getComputedStyle(document.querySelector('.cm-gutters')).display:'absent',paper:getComputedStyle(document.querySelector('#editor')).backgroundColor};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
            if let path = request["capture"] as? String {
                let image = try await web.takeSnapshot(configuration: nil)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)) }
            }
        case "focus": controller.session.sendCommand?(.focus)
        case "select":
            _ = try await web.callAsyncJavaScript("const e = document.querySelector('#editor').fieldnotesEditor; e.view.dispatch({selection:{anchor,head}})", arguments: ["anchor": request["anchor"] as? Int ?? 0, "head": request["head"] as? Int ?? 0], in: nil, contentWorld: .page)
        case "preview": controller.session.sendCommand?(.preview)
        case "pasteImage":
            _ = try await web.callAsyncJavaScript("""
                const e = document.querySelector('#editor').fieldnotesEditor;
                const prompt = window.prompt; window.prompt = () => alt;
                const bytes = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='), c => c.charCodeAt(0));
                const transfer = new DataTransfer(); transfer.items.add(new File([bytes], 'pixel.png', {type:'image/png'}));
                e.view.contentDOM.dispatchEvent(new ClipboardEvent('paste', {bubbles:true,cancelable:true,clipboardData:transfer}));
                window.prompt = prompt;
                """, arguments: ["alt": request["alt"] as? String ?? "Pixel"], in: nil, contentWorld: .page)
        case "replace":
            _ = try await web.callAsyncJavaScript("const e = document.querySelector('#editor').fieldnotesEditor; e.view.dispatch({changes:{from:0,to:e.view.state.doc.length,insert:text}})", arguments: ["text": request["text"] as? String ?? ""], in: nil, contentWorld: .page)
        case "save":
            guard let url = document.fileURL else { throw CocoaError(.fileNoSuchFile) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                document.save(to: url, ofType: document.fileType ?? "net.daringfireball.markdown", for: .saveOperation) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        case "resolve":
            if let conflict = document.state.conflict {
                let review = ConflictReview(conflict: conflict)
                review.choose(.merged(request["text"] as? String ?? ""))
                try document.confirmConflict(review)
            }
        default: break
        }
        var result = (try? await web.callAsyncJavaScript("const e = document.querySelector('#editor').fieldnotesEditor; return {text:e.view.state.doc.toString(),mode:e.mode,position:e.view.state.selection.main.head,anchor:e.view.state.selection.main.anchor,focusAlts:[...document.querySelectorAll('.fn-image-widget img')].map(i=>i.alt),previewAlts:[...document.querySelectorAll('article img')].map(i=>i.alt),imageLoaded:[...document.querySelectorAll('article img')].some(i=>i.complete&&i.naturalWidth>0),imageURL:document.querySelector('article img')?.getAttribute('src')||'',mermaid:!!document.querySelector('article svg')}", arguments: [:], in: nil, contentWorld: .page)) as? [String: Any] ?? [:]
        result["themeProof"] = themeProof
        result["page"] = (try? await web.evaluateJavaScript("({errors:window.integrationErrors,ready:document.readyState,diagnostics:document.querySelector('.fieldnotes-diagnostics')?.textContent,url:location.href})"))
        result["savePanel"] = controller.window?.attachedSheet is NSSavePanel
        result["firstSaveResult"] = firstSaveResult
        result["documentURL"] = document.fileURL?.path ?? ""
        result["automationMarker"] = "FIELDNOTES_INTEGRATION_CONTROL_V1"
        result["count"] = documents.count
        result["nativeText"] = document.state.editorText
        result["nativeSelection"] = [document.state.selection.anchor, document.state.selection.head]
        result["schema"] = String(describing: controller.session.schemaStatus)
        if let conflict = document.state.conflict {
            result["conflict"] = [String(decoding: conflict.base, as: UTF8.self), conflict.ours, String(decoding: conflict.theirs ?? Data(), as: UTF8.self)]
        }
        return result
    }
}
#endif
