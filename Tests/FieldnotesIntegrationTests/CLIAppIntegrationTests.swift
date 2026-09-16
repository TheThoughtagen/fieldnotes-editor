import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["FIELDNOTES_INTEGRATION_APP"] != nil))
struct CLIAppIntegrationTests {
    @Test func nativeThemeGeometryAfterRealAnimationFrames() async throws {
        let app = try AppHarness(); defer { app.stop() }
        let file = app.root.appendingPathComponent("themes.md")
        let source = "---\ntitle: Native theme proof\n---\n\n# Native heading\n\n## Second heading\n\nSetext heading\n===\n\n" + String(repeating: "A long document with **strong** text and `code`.\n\n", count: 100)
        try Data(source.utf8).write(to: file); try app.cli([file.path, "--mode", "focus"])
        _ = try await app.until { $0["text"] as? String == source }
        _ = try await app.command(["action":"theme", "theme":"midnight"])
        let output = ProcessInfo.processInfo.environment["FIELDNOTES_THEME_EVIDENCE"]
        for mode in ["source", "focus", "source"] {
            _ = try await app.command(["action":mode])
            _ = try await app.until { $0["mode"] as? String == mode }
            var request: [String: Any] = ["action":"themeMeasure"]
            if let output { request["capture"] = URL(fileURLWithPath: output).appendingPathComponent("theme-system-active-native-\(mode).png").path }
            let state = try await app.command(request), proof = try #require(state["themeProof"] as? [String: Any])
            #expect(proof["theme"] as? String == "midnight")
            #expect(state["nativeText"] as? String == source)
            if mode == "source" {
                let rows = try #require(proof["rows"] as? [[String: Double]])
                #expect(rows.count >= 10)
                #expect(rows.allSatisfy { abs(($0["gutter"] ?? -1000) - ($0["line"] ?? 1000)) < 1 })
            } else {
                #expect(["none", "absent"].contains(proof["gutter"] as? String ?? ""))
                #expect(abs(Double((proof["heading"] as? String ?? "").replacingOccurrences(of:"px",with:""))! - 28.8) < 0.001)
            }
            if let output { try JSONSerialization.data(withJSONObject: proof).write(to: URL(fileURLWithPath: output).appendingPathComponent("theme-system-active-native-\(mode).json")) }
        }
        _ = try await app.command(["action":"theme", "theme":"system"])
    }

    @Test func logicalSelectionsAndLiteralImageDescriptionsCrossNativeBrowserBoundary() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let file = app.root.appendingPathComponent("newlines.md")
        try Data("a\nb\nc".utf8).write(to: file)
        try app.cli([file.path, "--mode", "source"])
        _ = try await app.until { $0["text"] as? String == "a\nb\nc" }
        let variants = ["a\nb\nc", "a\r\nb\r\nc", "a\rb\r\nc", "a\r\nb\nc"]
        for before in variants {
            for after in variants {
                for selection in [[5, 5], [3, 3], [5, 2]] {
                    try app.externalWrite(before, to: file)
                    _ = try await app.until { $0["nativeText"] as? String == before && $0["text"] as? String == "a\nb\nc" }
                    _ = try await app.command(["action": "select", "anchor": selection[0], "head": selection[1]])
                    _ = try await app.until { $0["nativeSelection"] as? [Int] == selection }
                    let external = "z" + after.dropFirst()
                    try app.externalWrite(external, to: file)
                    let state = try await app.until { $0["nativeText"] as? String == external && $0["text"] as? String == "z\nb\nc" }
                    #expect(state["anchor"] as? Int == selection[0])
                    #expect(state["position"] as? Int == selection[1])
                    _ = try await app.command(["action": "save"])
                    #expect(try Data(contentsOf: file) == Data(external.utf8))
                }
            }
        }
        for literal in [#"Pump [A]"#, #"[open"#, #"close]"#, #"path\[A]\end"#, #"[[nested]] \\"#] {
            _ = try await app.command(["action": "replace", "text": "before\n"])
            _ = try await app.until { $0["nativeText"] as? String == "before\n" }
            _ = try await app.command(["action": "select", "anchor": 7, "head": 7])
            _ = try await app.command(["action": "pasteImage", "alt": literal])
            _ = try await app.until { ($0["nativeText"] as? String)?.contains("![") == true }
            _ = try await app.command(["action": "select", "anchor": 0, "head": 0])
            _ = try await app.command(["action": "focus"])
            _ = try await app.until { $0["focusAlts"] as? [String] == [literal] }
            _ = try await app.command(["action": "preview"])
            _ = try await app.until { $0["previewAlts"] as? [String] == [literal] && $0["imageLoaded"] as? Bool == true }
        }
    }

    @Test func cliOpensEditsSavesAndReusesCanonicalDocument() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let file = app.root.appendingPathComponent("note.md")
        try Data("first\r\nsecond\r\n".utf8).write(to: file)
        let schema = app.root.appendingPathComponent("schema.json")
        try Data(#"{"type":"object","required":["title"]}"#.utf8).write(to: schema)
        let alias = app.root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        try app.cli([file.path, "--schema", schema.path, "--mode", "source", "--line", "2", "--column", "3"])
        var state = try await app.until { $0["text"] as? String == "first\nsecond\n" && $0["mode"] as? String == "source" && $0["schema"] as? String == "invalid" }
        #expect(state["count"] as? Int == 1)
        #expect(state["position"] as? Int == 8)
        #expect(state["schema"] as? String == "invalid")
        _ = try await app.command(["action": "save"])
        #expect(try Data(contentsOf: file) == Data("first\r\nsecond\r\n".utf8))
        try app.cli([alias.path, "--schema", schema.path, "--mode", "preview"])
        state = try await app.until { $0["mode"] as? String == "preview" }
        #expect(state["count"] as? Int == 1)
        let exact = "---\ntitle: e\u{301}\n---\n\nend  \n"
        _ = try await app.command(["action": "replace", "text": exact])
        _ = try await app.until { $0["nativeText"] as? String == exact && $0["schema"] as? String == "valid" }
        _ = try await app.command(["action": "save"])
        #expect(try Data(contentsOf: file) == Data(exact.utf8))
        try app.externalWrite("clean\n", to: file)
        _ = try await app.until { $0["text"] as? String == "clean\n" }
        _ = try await app.command(["action": "replace", "text": "ours\n"])
        _ = try await app.until { $0["nativeText"] as? String == "ours\n" }
        try app.externalWrite("theirs\n", to: file)
        state = try await app.until { $0["conflict"] as? [String] == ["clean\n", "ours\n", "theirs\n"] }
        #expect(state["text"] as? String == "ours\n")
        _ = try await app.command(["action": "resolve", "text": "merged\n"])
        _ = try await app.until { $0["text"] as? String == "merged\n" }
        _ = try await app.command(["action": "save"])
        #expect(try String(contentsOf: file, encoding: .utf8) == "merged\n")
        _ = try await app.command(["action": "pasteImage"])
        state = try await app.until { ($0["nativeText"] as? String)?.contains("![Pixel](images/pixel.png)") == true && $0["imageLoaded"] as? Bool == true }
        #expect(state["imageURL"] as? String != nil)
        #expect(FileManager.default.fileExists(atPath: app.root.appendingPathComponent("images/pixel.png").path))
        _ = try await app.command(["action": "replace", "text": "```mermaid\ngraph TD\n A[Observe] --> B[Act]\n```\n"])
        state = try await app.until { $0["mermaid"] as? Bool == true }
        #expect((state["page"] as? [String: Any])?["errors"] as? [String] == [])
        _ = try await app.command(["action": "new"])
        _ = try await app.until { $0["count"] as? Int == 2 && $0["text"] as? String == "" }
        _ = try await app.command(["action": "firstSave"])
        _ = try await app.until { $0["savePanel"] as? Bool == true }
        _ = try await app.command(["action": "cancelSave"])
        state = try await app.until { $0["firstSaveResult"] as? String == "cancelled" }
        #expect(state["documentURL"] as? String == "")
        let firstSave = app.root.appendingPathComponent("untitled.md")
        _ = try await app.command(["action": "acceptNextFirstSave", "path": firstSave.path])
        _ = try await app.command(["action": "pasteImage"])
        state = try await app.until { ($0["nativeText"] as? String)?.contains("![Pixel](images/pixel-2.png)") == true }
        #expect(state["firstSaveResult"] as? String == firstSave.path)
        #expect(FileManager.default.fileExists(atPath: firstSave.path))
        _ = try await app.command(["action": "preview"])
        _ = try await app.until { $0["imageLoaded"] as? Bool == true }
        _ = try await app.command(["action": "save"])
        #expect(try String(contentsOf: firstSave, encoding: .utf8) == "![Pixel](images/pixel-2.png)")

    }
}

private final class AppHarness {
    let root: URL
    let app: URL
    let mailbox: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fieldnotes-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        app = root.appendingPathComponent("FIELDNOTES.app")
        try FileManager.default.copyItem(atPath: ProcessInfo.processInfo.environment["FIELDNOTES_INTEGRATION_APP"]!, toPath: app.path)
        mailbox = app.appendingPathComponent("Contents/Resources/integration")
        try FileManager.default.createDirectory(at: mailbox, withIntermediateDirectories: true)
    }
    func externalWrite(_ text: String, to url: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do { try Data(text.utf8).write(to: coordinated, options: .atomic) }
            catch { writeError = error }
        }
        if let error = coordinationError ?? writeError as NSError? { throw error }
    }
    func cli(_ arguments: [String]) throws {
        let process = Process(); process.executableURL = app.appendingPathComponent("Contents/MacOS/fieldnotes"); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    func command(_ value: [String: Any]) async throws -> [String: Any] {
        let id = UUID().uuidString
        var request = value; request["id"] = id
        try JSONSerialization.data(withJSONObject: request).write(to: mailbox.appendingPathComponent("request.json"), options: .atomic)
        for _ in 0..<300 {
            if let data = try? Data(contentsOf: mailbox.appendingPathComponent("response.json")),
               let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any], reply["id"] as? String == id {
                if let error = reply["error"] as? String { throw NSError(domain: error, code: 1) }
                return reply
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Integration app timed out: \(value); last=\((try? String(contentsOf: mailbox.appendingPathComponent("response.json"), encoding: .utf8)) ?? "none")", code: 1)
    }
    func until(_ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var last: [String: Any] = [:]
        for _ in 0..<100 {
            last = try await command(["action": "state"])
            if predicate(last) { return last }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "State timeout: \(last); disk=\((last["documentURL"] as? String).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "none")", code: 1)
    }
    func stop() {
        // Only the process that proved ownership of our private mailbox is terminated.
        if let text = try? String(contentsOf: mailbox.appendingPathComponent("pid"), encoding: .utf8), let pid = Int32(text) { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: root)
    }
}
