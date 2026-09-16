import AppKit
import Foundation
import Testing
@testable import FieldnotesApp

@Suite("External Markdown changes", .serialized)
@MainActor
struct ExternalChangeTests {
    let type = "public.plain-text"

    @Test("native read callbacks do not discard unsaved editor text")
    func dirtyReadPreservesOurs() throws {
        let document = FieldnotesDocument()
        try document.read(from: Data("base".utf8), ofType: type)
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try document.read(from: Data("theirs".utf8), ofType: type)
        #expect(document.state.editorText == "ours")
        #expect(document.state.baseText == "base")
    }

    @Test("presenter reload maps cursor past an inserted prefix")
    func cleanPresenterReload() async throws {
        let (document, url) = try fixture("hello world")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.updateSelection(.init(anchor: 6, head: 11))
        try Data("new hello world".utf8).write(to: url)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.editorText != "new hello world" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(document.state.editorText == "new hello world")
        #expect(document.state.selection == .init(anchor: 10, head: 15))
        #expect(!document.isDocumentEdited)
        let session = EditorSession(state: document.state)
        #expect(session.snapshot()["text"] as? String == "new hello world")
        #expect(session.snapshot()["selection"] as? [String: Int] == ["anchor": 10, "head": 15])
        try Data("x".utf8).write(to: url)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.editorText != "x" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.state.selection == .init(anchor: 1, head: 1))
    }

    @Test("native save catches an external edit before its notification arrives")
    func saveDoesNotOverwriteUnseenExternalEdit() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try Data("theirs".utf8).write(to: url)
        #expect(throws: (any Error).self) {
            try document.writeSafely(to: url, ofType: type, for: .saveOperation)
        }
        #expect(try Data(contentsOf: url) == Data("theirs".utf8))
        #expect(document.state.editorText == "ours")
        #expect(document.state.baseText == "base")
    }

    @Test("unresolved conflicts block native manual saves and autosaves")
    func conflictBlocksNativeSave() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try Data("theirs".utf8).write(to: url)
        try document.read(from: Data("theirs".utf8), ofType: type)
        for operation: NSDocument.SaveOperationType in [.saveOperation, .autosaveInPlaceOperation] {
            let error: Error? = await withCheckedContinuation { continuation in
                document.save(to: url, ofType: type, for: operation) { continuation.resume(returning: $0) }
            }
            #expect(error != nil)
            #expect(try Data(contentsOf: url) == Data("theirs".utf8))
        }
        let conflict = try #require(document.state.conflict)
        #expect(conflict.base == Data("base".utf8))
        #expect(conflict.ours == "ours")
        #expect(conflict.theirs == Data("theirs".utf8))
    }

    @Test("conflict choices retain all versions until confirmation and update native dirty accounting")
    func conflictChoicesRequireConfirmation() throws {
        for resolution: ConflictResolution in [.editor, .disk, .merged("merged")] {
            let (document, url) = try fixture("base")
            defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
            try document.read(from: Data("theirs".utf8), ofType: type)
            let conflict = try #require(document.state.conflict)
            let review = ConflictReview(conflict: conflict)
            review.choose(resolution)
            #expect(document.state.conflict == conflict)
            #expect(document.state.editorText == "ours")
            review.cancel()
            #expect(review.pending == nil)
            #expect(document.state.conflict == conflict)
            review.choose(resolution)
            try document.confirmConflict(review)
            #expect(document.state.conflict == nil)
            #expect(document.state.baseText == "theirs")
            switch resolution {
            case .editor: #expect(document.state.editorText == "ours"); #expect(document.isDocumentEdited)
            case .disk: #expect(document.state.editorText == "theirs"); #expect(!document.isDocumentEdited)
            case .merged: #expect(document.state.editorText == "merged"); #expect(document.isDocumentEdited)
            }
            #expect(try Data(contentsOf: url) == Data("base".utf8)) // confirmation alone never writes
        }
    }

    @Test("new editor or disk revisions invalidate an open confirmation")
    func staleConfirmationCannotDiscardNewVersions() throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try document.read(from: Data("theirs".utf8), ofType: type)
        let review = ConflictReview(conflict: try #require(document.state.conflict))
        review.choose(.disk)
        document.state.acceptEditorText("new ours", selection: .init(anchor: 8, head: 8), kind: .done)
        try document.confirmConflict(review)
        #expect(document.state.editorText == "new ours")
        #expect(document.state.conflict?.ours == "new ours")
        let second = ConflictReview(conflict: try #require(document.state.conflict))
        second.choose(.editor)
        try document.read(from: Data("new theirs".utf8), ofType: type)
        try document.confirmConflict(second)
        #expect(document.state.conflict?.theirs == Data("new theirs".utf8))
    }

    @Test("deletion callback retains text and requires explicit recreation")
    func deletionPreservesBuffer() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: url)
        let error: Error? = await withCheckedContinuation { continuation in
            document.accommodatePresentedItemDeletion { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        for _ in 0..<100 where document.state.conflict == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.state.editorText == "base")
        let review = ConflictReview(conflict: try #require(document.state.conflict))
        #expect(review.conflict.theirs == nil)
        #expect(document.isDocumentEdited)
        review.choose(.editor)
        try document.confirmConflict(review)
        #expect(document.state.diskWasDeleted)
        #expect(document.isDocumentEdited)
        try document.writeSafely(to: url, ofType: type, for: .saveOperation)
        #expect(try Data(contentsOf: url) == Data("base".utf8))
    }

    @Test("invalid UTF-8 cannot replace or be overwritten by the editor")
    func invalidExternalBytesBlockSave() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let invalid = Data([0xC3, 0x28])
        try invalid.write(to: url)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.externalReadError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.state.externalReadError != nil)
        #expect(document.state.editorText == "base")
        #expect(throws: (any Error).self) { try document.writeSafely(to: url, ofType: type, for: .saveOperation) }
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test("delayed reads reconcile against edits made while awaiting coordination")
    func pendingReadPreservesNewEdit() async throws {
        let gate = ReadGate()
        let document = FieldnotesDocument(externalChanges: .init(read: { _ in await gate.read() }))
        document.fileURL = URL(fileURLWithPath: "/tmp/read-gate.md")
        try document.read(from: Data("base".utf8), ofType: type)
        document.presentedItemDidChange()
        await gate.waitUntilStarted()
        document.state.acceptEditorText("new edit", selection: .init(anchor: 8, head: 8), kind: .done)
        await gate.finish(Data("theirs".utf8))
        for _ in 0..<100 where document.state.conflict == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.state.editorText == "new edit")
        #expect(document.state.conflict?.ours == "new edit")
    }

    @Test("a move invalidates pending reads from the former path")
    func moveRejectsOldRead() async throws {
        let gate = ReadGate()
        let document = FieldnotesDocument(externalChanges: .init(read: { url in
            if url.lastPathComponent == "old-gate.md" { return await gate.read() }
            return Data("base".utf8)
        }))
        document.fileURL = URL(fileURLWithPath: "/tmp/old-gate.md")
        try document.read(from: Data("base".utf8), ofType: type)
        document.presentedItemDidChange()
        await gate.waitUntilStarted()
        document.presentedItemDidMove(to: URL(fileURLWithPath: "/tmp/new-gate.md"))
        await gate.finish(Data("obsolete".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.state.editorText == "base")
        #expect(document.fileURL?.lastPathComponent == "new-gate.md")
    }

    @Test("successful native save notifications preserve subsequent edits and selection")
    func selfSaveDeduplicates() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("saved", selection: .init(anchor: 5, head: 5), kind: .done)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: type, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(document.state.baseText == "saved")
        document.state.acceptEditorText("newer", selection: .init(anchor: 2, head: 2), kind: .done)
        let revision = document.state.revision
        document.presentedItemDidChange()
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.state.editorText == "newer")
        #expect(document.state.selection == .init(anchor: 2, head: 2))
        #expect(document.state.revision == revision)
        #expect(document.state.conflict == nil)
    }

    @Test("saving a copy onto the conflicted original is still blocked")
    func saveToCannotBypassConflict() throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try Data("theirs".utf8).write(to: url)
        try document.read(from: Data("theirs".utf8), ofType: type)
        #expect(throws: (any Error).self) { try document.writeSafely(to: url, ofType: type, for: .saveToOperation) }
        #expect(try Data(contentsOf: url) == Data("theirs".utf8))
    }

    @Test("an external write during temporary output aborts atomic replacement")
    func externalWriteDuringSavePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-race-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        try Data("base".utf8).write(to: url)
        let document = FieldnotesDocument(byteWriter: { data, temporaryURL in
            try data.write(to: temporaryURL)
            try Data("during save".utf8).write(to: url)
        })
        defer { document.close() }
        try document.read(from: Data("base".utf8), ofType: type)
        document.fileURL = url
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        #expect(throws: (any Error).self) { try document.writeSafely(to: url, ofType: type, for: .saveOperation) }
        #expect(try Data(contentsOf: url) == Data("during save".utf8))
        #expect(document.state.editorText == "ours")
        #expect(document.state.conflict?.theirs == Data("during save".utf8))
    }

    @Test("native recovery autosaves do not promote the original disk baseline")
    func recoveryAutosavePreservesBaseline() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        let recoveryURL = url.deletingLastPathComponent().appendingPathComponent("recovery.md")
        try Data().write(to: recoveryURL)
        document.autosavedContentsFileURL = recoveryURL
        document.fileModificationDate = try recoveryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: recoveryURL, ofType: type, for: .autosaveElsewhereOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: recoveryURL) == Data("ours".utf8))
        #expect(try Data(contentsOf: url) == Data("base".utf8))
        #expect(document.state.baseText == "base")
        #expect(document.state.hasUnsavedText)
    }

    @Test("a newer edit during a native save survives snapshot promotion")
    func editDuringSavePreserved() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("edit-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("note.md")
        var document: FieldnotesDocument!
        document = FieldnotesDocument(byteWriter: { data, temporaryURL in
            try data.write(to: temporaryURL)
            document.state.acceptEditorText("newer", selection: .init(anchor: 5, head: 5), kind: .done)
        })
        defer { document.close(); document = nil }
        try document.read(from: Data("saved".utf8), ofType: type)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: url) == Data("saved".utf8))
        #expect(document.state.baseText == "saved")
        #expect(document.state.editorText == "newer")
        #expect(document.isDocumentEdited)
    }

    @Test("confirmed editor resolution can be saved through the native save lifecycle")
    func confirmedResolutionNativeSave() async throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try Data("theirs".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: url.path)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.conflict == nil { try await Task.sleep(for: .milliseconds(10)) }
        let review = ConflictReview(conflict: try #require(document.state.conflict))
        review.choose(.editor)
        try document.confirmConflict(review)
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: url, ofType: type, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        #expect(try Data(contentsOf: url) == Data("ours".utf8))
        #expect(document.state.baseText == "ours")
    }

    @Test("Save As invalidates a pending read of the previous location")
    func saveAsRejectsOldRead() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-read-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.md"), new = directory.appendingPathComponent("new.md")
        try Data("base".utf8).write(to: old)
        let gate = ReadGate()
        let document = FieldnotesDocument(externalChanges: .init(read: { url in
            if url.path == old.path { return await gate.read() }
            return try ExternalChangeCoordinator.diskData(at: url)
        }))
        defer { document.close() }
        try document.read(from: Data("base".utf8), ofType: type)
        document.fileURL = old
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        document.presentedItemDidChange()
        await gate.waitUntilStarted()
        let error: Error? = await withCheckedContinuation { continuation in
            document.save(to: new, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(error == nil)
        await gate.finish(Data("obsolete".utf8))
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.state.editorText == "ours")
        #expect(document.state.baseText == "ours")
        #expect(document.state.conflict == nil)
        #expect(try Data(contentsOf: new) == Data("ours".utf8))
    }

    @Test("copy, recovery, and failed saves retry an already-running external read")
    func savesRetryOutstandingRead() async throws {
        for mode in ["copy", "recovery", "failure"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("retry-read-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = directory.appendingPathComponent("original.md"), copy = directory.appendingPathComponent("copy.md")
            try Data("base".utf8).write(to: original)
            let gate = DelayedFirstRead()
            let document = FieldnotesDocument(externalChanges: .init(read: { try await gate.read($0) }), byteWriter: { data, target in
                if mode == "failure" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: target)
            })
            defer { document.close() }
            try document.read(from: Data("base".utf8), ofType: type)
            document.fileURL = original
            document.fileType = type
            document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
            try Data("theirs".utf8).write(to: original)
            document.presentedItemDidChange()
            await gate.waitUntilStarted()
            if mode == "recovery" {
                try Data().write(to: copy)
                document.autosavedContentsFileURL = copy
                document.fileModificationDate = try copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            let error: Error? = await withCheckedContinuation { continuation in
                document.save(to: copy, ofType: type, for: mode == "recovery" ? .autosaveElsewhereOperation : .saveToOperation) {
                    continuation.resume(returning: $0)
                }
            }
            #expect((error != nil) == (mode == "failure"))
            await gate.finish(Data("obsolete read".utf8))
            for _ in 0..<100 where document.state.conflict == nil { try await Task.sleep(for: .milliseconds(10)) }
            #expect(document.state.conflict?.theirs == Data("theirs".utf8), "mode: \(mode)")
            #expect(document.state.editorText == "ours")
            #expect(document.state.baseText == "base")
            #expect(document.fileURL?.path == original.path)
        }
    }

    @Test("Save As requires resolution before leaving a conflicted original")
    func saveAsRequiresConflictResolution() async throws {
        let (document, original) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let target = original.deletingLastPathComponent().appendingPathComponent("new.md")
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try Data("theirs".utf8).write(to: original)
        try document.read(from: Data("theirs".utf8), ofType: type)
        let conflict = try #require(document.state.conflict)
        let staleReview = ConflictReview(conflict: conflict)
        staleReview.choose(.disk)
        let rejected: Error? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(rejected != nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(document.fileURL?.path == original.path)
        #expect(document.state.conflict == conflict)
        let review = ConflictReview(conflict: conflict)
        review.choose(.editor)
        try document.confirmConflict(review)
        let saved: Error? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(saved == nil)
        try document.confirmConflict(staleReview)
        #expect(document.state.baseText == "ours")
        document.state.acceptEditorText("newer", selection: .init(anchor: 5, head: 5), kind: .done)
        let resaved: Error? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: type, for: .saveOperation) { continuation.resume(returning: $0) }
        }
        #expect(resaved == nil)
        #expect(try Data(contentsOf: target) == Data("newer".utf8))
        #expect(try Data(contentsOf: original) == Data("theirs".utf8))
    }

    @Test("Save As cannot carry an unreadable-original error to a new file")
    func saveAsRequiresReadableOriginal() async throws {
        let (document, original) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let target = original.deletingLastPathComponent().appendingPathComponent("new.md")
        try Data([0xFF]).write(to: original)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.externalReadError == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(document.state.externalReadError != nil)
        let rejected: Error? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(rejected != nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(document.fileURL?.path == original.path)
        try Data("base".utf8).write(to: original)
        document.presentedItemDidChange()
        for _ in 0..<100 where document.state.externalReadError != nil { try await Task.sleep(for: .milliseconds(10)) }
        let saved: Error? = await withCheckedContinuation { continuation in
            document.save(to: target, ofType: type, for: .saveAsOperation) { continuation.resume(returning: $0) }
        }
        #expect(saved == nil)
        #expect(document.state.externalReadError == nil)
        #expect(document.state.baseText == "base")
    }

    @Test("move reconciliation retries a pending change at the new location without another notification")
    func moveRetriesOutstandingReadAtNewLocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("move-read-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appendingPathComponent("old.md"), new = directory.appendingPathComponent("new.md")
        try Data("base".utf8).write(to: old)
        let gate = DelayedFirstRead()
        let document = FieldnotesDocument(externalChanges: .init(read: { try await gate.read($0) }))
        defer { document.close() }
        try document.read(from: Data("base".utf8), ofType: type)
        document.fileURL = old
        document.presentedItemDidChange()
        await gate.waitUntilStarted()
        try Data("changed then moved".utf8).write(to: old)
        try FileManager.default.moveItem(at: old, to: new)
        document.presentedItemDidMove(to: new)
        await gate.finish(Data("obsolete read".utf8))
        for _ in 0..<100 where document.state.editorText != "changed then moved" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await gate.urls.count >= 2)
        #expect(await gate.urls.last?.path == new.path)
        #expect(document.state.externalReadError == nil)
        #expect(document.state.conflict == nil)
        #expect(document.state.editorText == "changed then moved")
        #expect(document.state.baseText == "changed then moved")
        #expect(document.fileURL?.path == new.path)
    }

    @Test("merge drafts survive newer disk and editor versions while stale choices are invalidated")
    func mergeDraftSurvivesConflictRevisions() throws {
        let (document, url) = try fixture("base")
        defer { document.close(); try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        document.state.acceptEditorText("ours", selection: .init(anchor: 4, head: 4), kind: .done)
        try document.read(from: Data("theirs".utf8), ofType: type)
        let review = ConflictReview(conflict: try #require(document.state.conflict))
        review.mergeText = "authored merge draft"
        review.choose(.merged(review.mergeText))
        try document.read(from: Data("new disk".utf8), ofType: type)
        review.refresh(try #require(document.state.conflict))
        #expect(review.mergeText == "authored merge draft")
        #expect(review.pending == nil)
        #expect(review.conflict.theirs == Data("new disk".utf8))
        review.choose(.merged(review.mergeText))
        document.state.acceptEditorText("new editor", selection: .init(anchor: 10, head: 10), kind: .done)
        review.refresh(try #require(document.state.conflict))
        #expect(review.mergeText == "authored merge draft")
        #expect(review.pending == nil)
        #expect(review.conflict.ours == "new editor")
        review.choose(.merged(review.mergeText))
        try document.confirmConflict(review)
        #expect(document.state.editorText == "authored merge draft")
        #expect(document.state.baseText == "new disk")
        #expect(document.state.conflict == nil)
    }

    private func fixture(_ text: String) throws -> (FieldnotesDocument, URL) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("note.md")
        try Data(text.utf8).write(to: url)
        let document = try FieldnotesDocument(contentsOf: url, ofType: type)
        return (document, url)
    }
}

private actor ReadGate {
    private var continuation: CheckedContinuation<Data?, Never>?
    func read() async -> Data? {
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ data: Data?) { continuation?.resume(returning: data); continuation = nil }
}

private actor DelayedFirstRead {
    private(set) var urls: [URL] = []
    private var started = false
    private var continuation: CheckedContinuation<Data?, Never>?
    func read(_ url: URL) async throws -> Data? {
        urls.append(url)
        if started { return try ExternalChangeCoordinator.diskData(at: url) }
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        while continuation == nil { await Task.yield() }
    }
    func finish(_ data: Data?) { continuation?.resume(returning: data); continuation = nil }
}
