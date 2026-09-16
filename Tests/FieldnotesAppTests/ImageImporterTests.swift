import Foundation
import Testing
import FieldnotesCore
import AppKit
import WebKit
@testable import FieldnotesApp

private final class TestSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private(set) var finished = false
    private(set) var failed = false
    private(set) var callbackCount = 0
    init(_ url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { callbackCount += 1 }
    func didReceive(_ data: Data) { callbackCount += 1 }
    func didFinish() { callbackCount += 1; finished = true }
    func didFailWithError(_ error: any Error) { callbackCount += 1; failed = true }
}

private final class ResourceReadTracker: @unchecked Sendable {
    private let lock = NSLock(); private var released = false
    private(set) var active = 0; private(set) var maximum = 0; private(set) var starts = 0
    func read() throws -> Data {
        lock.withLock { active += 1; starts += 1; maximum = max(maximum, active) }
        defer { lock.withLock { active -= 1 } }
        while !lock.withLock({ released }) {
            if Task.isCancelled { throw CancellationError() }
            usleep(1_000)
        }
        return Data(Self.png)
    }
    func release() { lock.withLock { released = true } }
    func snapshot() -> (active: Int, maximum: Int, starts: Int) { lock.withLock { (active, maximum, starts) } }
    private static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private final class ImmediateReadTracker: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func read() -> Data { lock.withLock { count += 1 }; return Data([1]) }
    var returned: Int { lock.withLock { count } }
}

@Suite struct ImageImporterTests {
    private static let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    @Test func copyNeverOverwritesAndStaysInDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source")
        let images = root.appendingPathComponent("post/images")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("diagram.png")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let importer = ImageImporter()
        let first = try importer.copy(source, into: images)
        let second = try importer.copy(source, into: images)

        #expect(first.lastPathComponent == "diagram.png")
        #expect(second.lastPathComponent == "diagram-2.png")
        #expect(first.deletingLastPathComponent().standardizedFileURL == images.standardizedFileURL)
        #expect(try Data(contentsOf: second) == Data("pixels".utf8))
    }

    @Test func copySanitizesHostileNamesAndRejectsNonFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source")
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("my diagram (final).PNG")
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let imported = try ImageImporter().copy(source, into: images)
        #expect(imported.lastPathComponent == "my-diagram-final.png")
        #expect(throws: ImageImportError.sourceIsNotARegularFile) {
            try ImageImporter().copy(sourceDirectory, into: images)
        }
    }

    @Test func imagesSymlinkCannotEscapeAuthorizedDocumentDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let post = root.appendingPathComponent("post")
        let outside = root.appendingPathComponent("outside")
        let source = root.appendingPathComponent("source.png")
        try FileManager.default.createDirectory(at: post, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: post.appendingPathComponent("images"), withDestinationURL: outside)
        try Data("pixels".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: ImageImportError.destinationEscaped) {
            try ImageImporter().copy(source, into: post.appendingPathComponent("images"), authorizedRoot: post)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    @Test func destinationSwapBeforeDescriptorOpenCannotWriteOutsideRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let post = root.appendingPathComponent("post"), images = post.appendingPathComponent("images"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importer = ImageImporter {
            try FileManager.default.moveItem(at: images, to: post.appendingPathComponent("old-images"))
            try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
        }

        #expect(throws: ImageImportError.destinationEscaped) {
            try importer.write(Data("pixels".utf8), suggestedName: "a.png", into: images, authorizedRoot: post)
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    @Test func authorizedRootAncestorSwapCannotRedirectReadOrWrite() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trustedParent = fixture.appendingPathComponent("trusted"), trustedRoot = trustedParent.appendingPathComponent("root")
        let outsideParent = fixture.appendingPathComponent("outside"), outsideRoot = outsideParent.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try Data("INSIDE".utf8).write(to: trustedRoot.appendingPathComponent("a.png"))
        try Data("OUTSIDE".utf8).write(to: outsideRoot.appendingPathComponent("a.png"))
        defer { try? FileManager.default.removeItem(at: fixture) }
        let authority = try SecureDirectoryAuthority(granting: trustedRoot)
        try FileManager.default.moveItem(at: trustedParent, to: fixture.appendingPathComponent("trusted-old"))
        try FileManager.default.createSymbolicLink(at: trustedParent, withDestinationURL: outsideParent)

        #expect(throws: (any Error).self) {
            try SecureFileIO.read(relativeComponents: ["a.png"], authority: authority, maximumBytes: 50)
        }
        #expect(throws: (any Error).self) {
            try SecureFileIO.writeUnique(Data("new".utf8), suggestedName: "b.png", directoryName: "images", authority: authority)
        }
        #expect(!FileManager.default.fileExists(atPath: outsideRoot.appendingPathComponent("images/b.png").path))
    }

    @Test @MainActor func resourceResolverRejectsTraversalStaleGenerationAndUnsupportedScheme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("images/a.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ResourceResolver { .init(generation: 7, allowedRoot: root) }

        #expect(try resolver.resolve(URL(string: "fieldnotes-resource://7/resource?path=images%2Fa.png")!) == image.standardizedFileURL)
        #expect(throws: ResourceError.outsideAllowedRoot) {
            try resolver.resolve(URL(string: "fieldnotes-resource://7/resource?path=..%2Fsecret.png")!)
        }
        #expect(throws: ResourceError.staleGeneration) {
            try resolver.resolve(URL(string: "fieldnotes-resource://6/resource?path=images%2Fa.png")!)
        }
        #expect(throws: ResourceError.unsupportedScheme) {
            try resolver.resolve(URL(string: "file:///tmp/a.png")!)
        }
    }

    @Test @MainActor func resourceResolverDecodesOneMarkdownURLLayerAndRejectsMalformedEncoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let image = root.appendingPathComponent("my diagram (100%).png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("pixels".utf8).write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ResourceResolver { .init(generation: 1, allowedRoot: root) }

        #expect(try resolver.resolve(URL(string: "fieldnotes-resource://1/resource?path=my%2520diagram%2520%2528100%2525%2529.png")!).path == image.path)
        #expect(throws: ResourceError.malformedRequest) {
            try resolver.resolve(URL(string: "fieldnotes-resource://1/resource?path=bad%252G.png")!)
        }
    }

    @Test @MainActor func resourceReadIsDescriptorAnchoredAndImageTyped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let images = root.appendingPathComponent("images"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("safe".utf8).write(to: images.appendingPathComponent("a.png"))
        try Data("secret".utf8).write(to: outside.appendingPathComponent("a.png"))
        try Data("text".utf8).write(to: root.appendingPathComponent("note.txt"))
        try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: root.appendingPathComponent("vector.svg"))
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = ResourceResolver { .init(generation: 1, allowedRoot: root) }

        #expect(throws: (any Error).self) {
            try resolver.load(URL(string: "fieldnotes-resource://1/resource?path=images%2Fa.png")!) {
                try FileManager.default.moveItem(at: images, to: root.appendingPathComponent("old-images"))
                try FileManager.default.createSymbolicLink(at: images, withDestinationURL: outside)
            }
        }
        #expect(throws: ResourceError.unavailable) {
            try resolver.load(URL(string: "fieldnotes-resource://1/resource?path=note.txt")!)
        }
        let svg = try resolver.load(URL(string: "fieldnotes-resource://1/resource?path=vector.svg")!)
        #expect(svg.mimeType == "image/svg+xml")
        #expect(String(decoding: svg.data, as: UTF8.self).contains("<svg"))
    }

    @Test @MainActor func resourceHandlerQueuesPastWorkerLimitAndCancellationFreesCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(base64Encoded: Self.pngBase64)?.write(to: root.appendingPathComponent("a.png"))
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = ResourceReadTracker()
        let handler = ResourceSchemeHandler(resolver: ResourceResolver { ResourceScope(generation: 1, allowedRoot: root) }) { _ in try tracker.read() }
        let url = try #require(URL(string: "fieldnotes-resource://1/resource?path=a.png"))
        let tasks = (0..<10).map { _ in TestSchemeTask(url) }
        let webView = WKWebView()
        tasks.forEach { handler.webView(webView, start: $0) }
        while tracker.snapshot().0 < 8 { await Task.yield() }
        #expect(tracker.snapshot().maximum == 8)
        #expect(tracker.snapshot().starts == 8)

        handler.webView(webView, stop: tasks[0])
        while tracker.snapshot().starts < 9 { await Task.yield() }
        #expect(tracker.snapshot().maximum == 8)
        tracker.release()
        while tasks.dropFirst().contains(where: { !$0.finished && !$0.failed }) { await Task.yield() }
        #expect(tasks.dropFirst().allSatisfy { $0.finished })
        #expect(tasks.allSatisfy { !$0.failed })
    }

    @Test @MainActor func stoppedResourceAfterReadBeforeActorDeliveryGetsNoCallbacksAndQueueProgresses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(base64Encoded: Self.pngBase64)?.write(to: root.appendingPathComponent("a.png"))
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = ImmediateReadTracker()
        let handler = ResourceSchemeHandler(resolver: ResourceResolver { ResourceScope(generation: 1, allowedRoot: root) }) { _ in tracker.read() }
        let url = try #require(URL(string: "fieldnotes-resource://1/resource?path=a.png"))
        let tasks = (0..<9).map { _ in TestSchemeTask(url) }, webView = WKWebView()
        tasks.forEach { handler.webView(webView, start: $0) }
        while tracker.returned < 8 { usleep(1_000) }

        handler.webView(webView, stop: tasks[0])
        while !tasks[8].finished { await Task.yield() }

        #expect(tasks[0].callbackCount == 0)
        #expect(tasks[8].callbackCount == 3)
    }

    @Test @MainActor func sessionScopesResourcesToActiveDocumentPolicyAndConfigurationRegistersOnlyCustomScheme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("posts/entry.md")
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: document, schema: .none, localAssetPolicy: .documentDirectory), requestedMode: nil, line: nil, column: nil))

        #expect(session.resourceScope?.generation == 1)
        #expect(session.resourceScope?.allowedRoot.path == document.deletingLastPathComponent().standardizedFileURL.path)
        let registration = EditorWebConfiguration.make(session: session)
        #expect(registration.resourceHandler != nil)
        #expect(registration.configuration.urlSchemeHandler(forURLScheme: "file") == nil)
        registration.teardown()
    }

    @Test @MainActor func sessionImportCopiesBesideSavedDocumentAndReturnsOnlyRelativeMarkdownData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("posts/entry.md")
        try FileManager.default.createDirectory(at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: document, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"Gateway Shot.PNG","mimeType":"image/png","dataBase64":"\#(Self.pngBase64)","altText":"Gateway status","linkInPlace":false,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply
        #expect(reply["kind"] as? String == "imageImported")
        #expect(reply["path"] as? String == "images/gateway-shot.png")
        #expect(reply["altText"] as? String == "Gateway status")
        #expect(try Data(contentsOf: root.appendingPathComponent("posts/images/gateway-shot.png")) == Data(base64Encoded: Self.pngBase64))
    }

    @Test @MainActor func importedAltEscapesLiteralBracketsAndBackslashes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: root.appendingPathComponent("note.md"), schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        for (literal, escaped) in [(#"Pump [A]"#, #"Pump \[A\]"#), (#"[open"#, #"\[open"#), (#"close]"#, #"close\]"#), (#"path\[A]\end"#, #"path\\\[A\]\\end"#)] {
            let body: [String: Any] = ["kind": "imageImport", "documentID": "doc", "baseRevision": 0, "revision": 0,
                "payload": ["filename": "pixel.png", "mimeType": "image/png", "dataBase64": Self.pngBase64, "altText": literal, "linkInPlace": false, "generation": 1]]
            let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply
            #expect(reply["kind"] as? String == "imageImported")
            #expect(reply["altText"] as? String == escaped)
        }
    }

    @Test @MainActor func unsavedSessionRequiresNativeSaveLocationBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"\#(Self.pngBase64)","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))

        session.onEnsureSaveLocation = { nil }
        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImportCancelled")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
    }

    @Test @MainActor func freshUntitledDocumentInstallsImportHandshakeWithoutReadAuthority() throws {
        _ = NSApplication.shared
        let document = FieldnotesDocument()

        document.makeWindowControllers()

        let controller = try #require(document.windowControllers.first as? DocumentWindowController)
        #expect(controller.session.contextGeneration == 1)
        #expect(controller.session.currentDocumentURL == nil)
        #expect(controller.session.resourceScope == nil)
        #expect(controller.session.onEnsureSaveLocation != nil)
    }

    @Test @MainActor func nativeRemoteImagePreferenceIsDisabledByDefaultAndReplaysContextWhenToggled() throws {
        let suite = "remote-images-\(UUID().uuidString)", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = EditorSession(state: DocumentState(), documentID: "doc", defaults: defaults)
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        #expect(session.remoteImagesEnabled == false)
        #expect((session.snapshot()["openContext"] as? [String: Any])?["allowRemoteImages"] as? Bool == false)

        session.toggleRemoteImages()

        #expect(session.remoteImagesEnabled == true)
        #expect(session.contextGeneration == 2)
        #expect((session.snapshot()["openContext"] as? [String: Any])?["allowRemoteImages"] as? Bool == true)
    }

    @Test @MainActor func saveAsRefreshesResourceRootAndInvalidatesOldGeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("one/entry.md")
        let second = root.appendingPathComponent("two/entry.md")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"localAssetPolicy":"document-directory"}"#.utf8).write(to: root.appendingPathComponent(".fieldnotes.json"))
        try Data().write(to: second)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: first, schema: .none, localAssetPolicy: .documentDirectory), requestedMode: nil, line: nil, column: nil))

        try session.refreshDocumentLocation(second)

        #expect(session.resourceScope?.generation == 2)
        #expect(session.resourceScope?.allowedRoot.path == second.deletingLastPathComponent().path)
    }

    @Test @MainActor func nativePresentedItemMoveRefreshesAuthorityWithoutSave() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("one/entry.md"), second = root.appendingPathComponent("two/entry.md")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git")); try Data().write(to: first)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = FieldnotesDocument(); document.fileURL = first; document.makeWindowControllers()
        let session = try #require((document.windowControllers.first as? DocumentWindowController)?.session)
        let oldGeneration = session.contextGeneration
        try FileManager.default.moveItem(at: first, to: second)

        document.presentedItemDidMove(to: second)

        #expect(session.contextGeneration == oldGeneration + 1)
        #expect(session.currentDocumentURL?.path == second.path)
    }

    @Test @MainActor func unsavedImportResumesAfterNativeSaveAndUsesNewGenerationRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("entry.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git"))
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        session.onEnsureSaveLocation = {
            try? Data().write(to: document)
            session.authorizeFirstSaveTransition(to: document)
            return document
        }
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"\#(Self.pngBase64)","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect(session.resourceScope?.generation == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/a.png").path))
    }

    @Test @MainActor func firstSaveThroughDocumentCallbackRefreshesContextOnceAndResumesImport() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("entry.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git"))
        defer { try? FileManager.default.removeItem(at: root) }
        let document = FieldnotesDocument()
        document.makeWindowControllers()
        let session = try #require((document.windowControllers.first as? DocumentWindowController)?.session)
        let startingGeneration = session.contextGeneration
        session.onEnsureSaveLocation = {
            session.authorizeFirstSaveTransition(to: destination)
            let error = await withCheckedContinuation { continuation in
                document.save(to: destination, ofType: "public.plain-text", for: .saveAsOperation) {
                    continuation.resume(returning: $0)
                }
            }
            return error == nil ? document.fileURL : nil
        }
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"\#(session.documentID)","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"\#(Self.pngBase64)","altText":"A","linkInPlace":false,"generation":\#(startingGeneration)}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect(document.fileURL?.standardizedFileURL == destination.standardizedFileURL)
        #expect(session.contextGeneration == startingGeneration + 1)
        #expect(session.currentDocumentURL == destination.resolvingSymlinksInPath().standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/a.png").path))
    }

    @Test @MainActor func optionLinkWithoutBrowserPathUsesNativeSelectionAndKeepsFileInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("entry.md"), image = root.appendingPathComponent("diagram.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(base64Encoded: Self.pngBase64)?.write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: document, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        session.onChooseLinkInPlaceImage = { image }
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"diagram.png","mimeType":"image/png","altText":"Diagram","linkInPlace":true,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect(reply["path"] as? String == "diagram.png")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
    }

    @Test @MainActor func documentDirectoryLinkInPlaceReturnsPublicationDiagnostic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("entry.md")
        let image = root.appendingPathComponent("diagram.png")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: image)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: document, schema: .none, localAssetPolicy: .documentDirectory), requestedMode: nil, line: nil, column: nil))
        let payload = #"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"diagram.png","mimeType":"image/png","sourceURL":"FILE_URL","altText":"Diagram","linkInPlace":true,"generation":1}}"#.replacingOccurrences(of: "FILE_URL", with: image.absoluteString)
        let body = try JSONSerialization.jsonObject(with: Data(payload.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect((reply["diagnostic"] as? String)?.contains("publication") == true)
    }

    @Test @MainActor func forgedImageMIMEWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("entry.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: document, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"secret.png","mimeType":"image/png","dataBase64":"c2VjcmV0IHRleHQ=","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImportFailed")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
    }

    @Test @MainActor func bridgeTeardownCancelsDeferredFirstSaveBeforeAssetMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let document = root.appendingPathComponent("entry.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".git"))
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        var resumeSave: ((URL?) -> Void)?
        session.onEnsureSaveLocation = {
            await withCheckedContinuation { continuation in resumeSave = { continuation.resume(returning: $0) } }
        }
        let handler = WeakEditorReplyHandler(session: session)
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"\#(Self.pngBase64)","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))
        var replyError: String?

        handler.handle(body: body, isMainFrame: true) { _, error in replyError = error }
        while resumeSave == nil { await Task.yield() }
        handler.markRemoved()
        try Data().write(to: document)
        resumeSave?(document)
        for _ in 0..<5 { await Task.yield() }

        #expect(replyError == "editor session unavailable")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
    }
}
