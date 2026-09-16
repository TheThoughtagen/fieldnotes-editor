import Foundation
import Testing
@testable import FieldnotesApp

struct NativeSchemaValidatorTests {
    @Test func sharedValidatorSupportsFormatsRefsAndDynamicRefsWithoutWebEval() throws {
        let script = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/editor-web/schema-validator.js")
        #expect(FileManager.default.fileExists(atPath: script.path), "Run npm run build before Swift tests")
        let schema = Data(##"{"$schema":"https://json-schema.org/draft/2020-12/schema","$dynamicAnchor":"node","type":"object","required":["title"],"properties":{"title":{"type":"string"},"date":{"type":"string","format":"date"},"child":{"$dynamicRef":"#node"}}}"##.utf8)
        func diagnostics(_ source: String) throws -> [[String: String]] {
            try #require(JSONSerialization.jsonObject(with: NativeSchemaValidator.validate(source: source, schema: schema, scriptURL: script)) as? [[String: String]])
        }
        #expect(try diagnostics("---\ntitle: Ready\ndate: '2026-09-15'\nchild:\n  title: Child\n---\n").isEmpty)
        #expect(try diagnostics("---\ntitle: Ready\ndate: bad\n---\n") == [["code": "schema.format", "message": "/date must match format \"date\"", "severity": "error"]])
        #expect(try diagnostics("---\ntitle: Ready\nchild: {}\n---\n") == [["code": "schema.required", "message": "/child must have required property 'title'", "severity": "error"]])
        let remote = NativeSchemaValidator.validate(source: "---\ntitle: Ready\n---\n", schema: Data(##"{"$ref":"https://example.com/schema.json"}"##.utf8), scriptURL: script)
        #expect(String(decoding: remote, as: UTF8.self).contains("schema.validation"))
    }

    @Test func validationBridgeRejectsCodeAndSubframes() throws {
        let body: [String: Any] = ["kind": "schemaValidate", "documentID": "doc", "revision": 0, "baseRevision": 0, "payload": ["generation": 1]]
        #expect(try EditorBridgeRequest.validate(body: body, isMainFrame: true).kind == .schemaValidate)
        #expect(throws: (any Error).self) { try EditorBridgeRequest.validate(body: body, isMainFrame: false) }
        var injected = body; injected["payload"] = ["generation": 1, "source": "arbitrary code"]
        #expect(throws: (any Error).self) { try EditorBridgeRequest.validate(body: injected, isMainFrame: true) }
    }
}
