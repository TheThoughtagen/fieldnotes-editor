import Foundation
import Testing
@testable import FieldnotesApp
@testable import FieldnotesCore

@Suite("Application open routing", .serialized)
@MainActor
struct OpenRoutingTests {
    @Test("ordinary cold launch requests an untitled document")
    func ordinaryLaunch() {
        let queue = OpenRequestQueue { _ in }
        #expect(queue.shouldOpenUntitled)
        queue.applicationDidFinishLaunching()
        #expect(queue.shouldOpenUntitled)
    }

    @Test("cold launch queues and drains requests in arrival order")
    func coldOrder() throws {
        var opened: [String] = []
        let queue = OpenRequestQueue { opened.append($0.target.lastPathComponent) }
        let first = OpenRequest(target: URL(fileURLWithPath: "/tmp/one.md"))
        let second = OpenRequest(target: URL(fileURLWithPath: "/tmp/two.md"))

        queue.enqueue(first)
        queue.enqueue(second)
        #expect(opened.isEmpty)
        #expect(queue.shouldOpenUntitled == false)
        queue.applicationDidFinishLaunching()
        #expect(opened == ["one.md", "two.md"])

        queue.enqueue(OpenRequest(target: URL(fileURLWithPath: "/tmp/three.md")))
        #expect(opened == ["one.md", "two.md", "three.md"])
    }

    @Test("canonical aliases reuse the existing document URL")
    func canonicalReuse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("note.md")
        let alias = root.appendingPathComponent("alias.md")
        try Data().write(to: real)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        #expect(CanonicalDocumentLookup.matching(alias, in: [real]) == real)
        #expect(CanonicalDocumentLookup.matching(root.appendingPathComponent("other.md"), in: [real]) == nil)
    }
}
