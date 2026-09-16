# Task 7 native save SIGTRAP diagnosis

The persistent SIGTRAP is a Swift actor-isolation assertion in the Objective-C thunk for `FieldnotesDocument.preservesVersions`. AppKit queries this class policy on a background queue during version preservation after an ordinary save. The override currently inherits main-actor isolation from `NSDocument`, although its implementation returns only the constant `true`.

## Direct evidence

Read-only inspection of macOS crash reports found the same stack in all 16 available reports dated September 15, 2026 between 21:46 and 22:02. Representative report:

`/Users/pmannion/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-09-15-220252.ips`

Exception: `EXC_BREAKPOINT`, signal `SIGTRAP`. Triggered queue: `com.apple.root.default-qos`.

```text
_dispatch_assert_queue_fail
 dispatch_assert_queue$V2.cold.1
 dispatch_assert_queue
 _swift_task_checkIsolatedSwift
 swift_task_isCurrentExecutorWithFlagsImpl
 _checkExpectedExecutor
 @objc static FieldnotesDocument.preservesVersions.getter
 -[NSDocument(NSDocument_Versioning) _preserveContentsIfNecessaryAfterWriting:toURL:forSaveOperation:version:error:]
 __85-[NSDocument(NSDocumentSaving) _saveToURL:ofType:forSaveOperation:completionHandler:]_block_invoke_2.401
 _dispatch_call_block_and_release
```

Reports ending `220039`, `220157`, and `220225` confirm the identical failure independently. Earlier reports ending `214607` through `215926` also name the same getter on the same background queue. This is stronger evidence than timing correlations with presenter callbacks. `/tmp/task7-accounting-trace.log` proves reconciliation returned before the later native versioning task asserted; it does not implicate that reconciliation in the assertion.

## Smallest correction

```swift
nonisolated override class var preservesVersions: Bool { true }
```

Apply the same explicit nonisolated annotation to constant class policies such as `autosavesInPlace` and `canConcurrentlyReadDocuments(ofType:)` when accepted by the compiler. These callbacks need no access to actor-owned document state. Keep state mutations and UI handling actor-isolated.

No signal handler, disabling versioning, inserted sleep, or replacement of `.saveOperation` with `.saveAsOperation` is warranted. AppKit background work explains why a handler or suppression of presenter work can change whether the task reaches the assertion before the short test process exits. That timing explanation is inferred; the crashing getter itself is proven by the reports.

The coordinator exclusion of the document presenter is a separate coordination design decision and does not repair this getter. Do not use this crash diagnosis to weaken external-write protection or read coordination.

## Verification and lifecycle

The implementer has received the finding and is applying the annotation and rerunning `swift test --filter ExternalChangeTests.selfSaveDeduplicates`. No diagnostic code or test changes were made by this investigation. After annotation, repeat the actual ordinary-save test and then the relevant complete suite; preserve successful save completion and explicit `document.close()` cleanup. No additional test-lifecycle workaround is indicated by the crash stack.

The supplied `/tmp/task7-hang.sample` is a different failure: its main thread is inside `makeWindowControllers()` → `WorkspaceResolver.resolve` → `nearestWorkspace`, with a 10.5 GB footprint. It contains no evidence that the SIGTRAP arose in reconciliation; window creation was an investigative detour. Treat any workspace traversal hang separately if it reproduces in required production behavior.

Scope: read-only source, logs, sample and crash-report inspection. Only this report was written; no shared build or source files were changed.
