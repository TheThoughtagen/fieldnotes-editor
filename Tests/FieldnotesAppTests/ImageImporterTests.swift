import Foundation
import Testing
import FieldnotesCore
@testable import FieldnotesApp

@Suite struct ImageImporterTests {
    @Test func copyNeverOverwritesAndStaysInDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceDirectory = root.appendingPathComponent("source")
        let images = root.appendingPathComponent("post/images")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
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
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"Gateway Shot.PNG","mimeType":"image/png","dataBase64":"cGl4ZWxz","altText":"Gateway status","linkInPlace":false,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect(reply["path"] as? String == "images/gateway-shot.png")
        #expect(reply["altText"] as? String == "Gateway status")
        #expect(try Data(contentsOf: root.appendingPathComponent("posts/images/gateway-shot.png")) == Data("pixels".utf8))
    }

    @Test @MainActor func unsavedSessionRequiresNativeSaveLocationBeforeImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = EditorSession(state: DocumentState(), documentID: "doc")
        session.installOpenContext(.init(context: WorkspaceContext(workspace: root, document: nil, schema: .none, localAssetPolicy: .workspace), requestedMode: nil, line: nil, column: nil))
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"cA==","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))

        session.onEnsureSaveLocation = { nil }
        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImportCancelled")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("images").path))
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
            return document
        }
        let body = try JSONSerialization.jsonObject(with: Data(#"{"kind":"imageImport","documentID":"doc","baseRevision":0,"revision":0,"payload":{"filename":"a.png","mimeType":"image/png","dataBase64":"cA==","altText":"A","linkInPlace":false,"generation":1}}"#.utf8))

        let reply = await session.prepareImageImportResponse(to: try EditorBridgeRequest.decode(body: body)).reply

        #expect(reply["kind"] as? String == "imageImported")
        #expect(session.resourceScope?.generation == 2)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("images/a.png").path))
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
}
