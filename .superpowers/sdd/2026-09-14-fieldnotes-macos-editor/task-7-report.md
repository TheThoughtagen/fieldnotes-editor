# Task 7 — External Markdown reconciliation

Implemented against baseline `dca2986` on `branchfeat/macos-editor`. Final gate: **98 Swift tests passed, 8 suites**. No renderer/npm sources changed, so no npm build-dependent checks were needed.

## Behavior and implementation

- Native `presentedItemDidChange` callbacks hop to MainActor, read through an NSFileCoordinator on a worker task using the accessor URL, and reconcile only if the document location/read generation is still current. Reads use `.withoutChanges` and exclude the initiating document presenter. Notifications during a native save are deferred until its completion; closing, moving, resolving, and saving invalidate stale reads.
- Clean changes keep the same DocumentState and editor session, advance bridge revisions, map UTF-16 selections through common prefix/suffix text, and clamp positions without splitting a surrogate pair. Bridge snapshot assertions cover the new text and mapped cursor.
- Dirty changes retain exact base/disk bytes and the editor text in an observable three-way conflict. Native SwiftUI comparison exposes last saved/editor/disk, a manual merge draft, and explicit confirmation for editor, disk, or merged content. Stale confirmations cannot discard newer editor/disk revisions. Confirmation alone does not write. NSDocument dirty accounting and modification dates follow the selected baseline.
- Manual saves, in-place autosaves, and Save To aimed at the conflicted original are blocked while unresolved. Native `writeSafely` checks actual disk bytes before output and checks again after temporary output is written; the latter aborts replacement if an uncoordinated writer changes the original during serialization. NSDocument remains the coordinated/atomic writer; no nested independent writer was introduced.
- Native saves write their captured snapshot, promote only successful original-file saves, and preserve edits made during saving. Save To/recovery autosaves do not promote the original disk baseline. SHA-256 self-save deduplication also requires equality with the current baseline, so a historical digest cannot suppress a different current state.
- Deletion preserves the buffer and marks the document edited; explicit editor/merge confirmation enables recreation. Invalid UTF-8/read failures preserve the buffer and block overwriting the original. Move callbacks retain Task 6 location/authority refresh behavior.
- A native file-reference URL uncovered unbounded workspace ancestor traversal at `/`. Both workspace and config/schema discovery now stop explicitly at the filesystem root. The controller requested this production integration fix after independently reproducing it.

## RED/GREEN evidence

Logs are retained in [task-7-logs](task-7-logs/). Commands below ran from `/tmp/fieldnotes-editor-macos`.

| Command | Result and evidence |
| --- | --- |
| `swift test --filter ExternalChangeTests` | Initial RED: 3 tests, 6 expected assertion failures: dirty read discarded ours, presenter did not reload/map cursor, native safe write overwrote an unseen external edit. [red.log](task-7-logs/red.log) |
| `swift test --filter ExternalChangeTests` | Next RED: new confirmation tests could not compile because `ConflictReview` / `confirmConflict` were absent. This was a missing-interface RED, not a runtime assertion. [red2.log](task-7-logs/red2.log) |
| `swift test --filter 'ExternalChangeTests.(saveToCannotBypassConflict\|externalWriteDuringSavePreserved\|recoveryAutosavePreservesBaseline\|editDuringSavePreserved)'` | SaveTo bypass and during-output external-write tests failed their preservation assertions. The newer-editor-during-save characterization already passed. Recovery fixture initially failed before writing because NSDocument recovery URL/date metadata was absent; after supplying native autosaved URL and date metadata it exercises real successful recovery writes. [red-savecases.log](task-7-logs/red-savecases.log). The actual shell command used regex alternatives `\|` without the backslashes shown here for Markdown table escaping. |
| `swift test --filter 'ExternalChangeTests.(confirmedResolutionNativeSave\|recoveryAutosavePreservesBaseline)'` | Recovery passed with corrected native fixture. Confirmed editor resolution failed with native error 67000 until the accepted disk modification date was adopted; disk stayed intact. [native-resolution-red.log](task-7-logs/native-resolution-red.log) |
| `swift test --filter WorkspaceCoreTests.fileReferenceWorkspaceStopsAtRoot` | RED: build completed; resolver loop exceeded a 15-second subprocess deadline. Python `subprocess.Popen(..., start_new_session=True)`, `p.wait(timeout=15)`, then `os.killpg(p.pid, signal.SIGTERM)` bounded the reproduction. [workspace-red.log](task-7-logs/workspace-red.log) |
| `swift test --filter ExternalChangeTests.selfSaveDeduplicates` | GREEN after the native Versions policy actor fix. [actor-fix.log](task-7-logs/actor-fix.log) |
| `swift test --filter 'ExternalChangeTests\|WorkspaceCoreTests.fileReferenceWorkspaceStopsAtRoot'` | 18 focused tests passed, including save/move stale-read rejection, cursor/bridge updates, conflict resolution, deletion, invalid bytes, snapshot races, and root traversal. Actual shell regex used unescaped `\|`. [focused-final.log](task-7-logs/focused-final.log) |
| `swift test` | First full gate found one existing geometry assertion regression: installing the hosting view after setting the frame shrank the window to its minimum. [full-swift.log](task-7-logs/full-swift.log) |
| `swift test --filter DocumentStateTests.documentWindowUsesPersistentState` | Passed after setting the initial frame after hosting-view installation, preserving 960×720. [window-green.log](task-7-logs/window-green.log) |
| `swift test` | Final gate: **98 tests passed, 8 suites**. [full-swift-final.log](task-7-logs/full-swift-final.log) |
| `git diff --check` | Passed; no whitespace errors. |

Literal regex commands (without Markdown table escaping):

```sh
swift test --filter 'ExternalChangeTests.(saveToCannotBypassConflict|externalWriteDuringSavePreserved|recoveryAutosavePreservesBaseline|editDuringSavePreserved)'
swift test --filter 'ExternalChangeTests.(confirmedResolutionNativeSave|recoveryAutosavePreservesBaseline)'
swift test --filter 'ExternalChangeTests|WorkspaceCoreTests.fileReferenceWorkspaceStopsAtRoot'
```

The SaveAs-old-read and bridge-selection assertions extend coverage of already implemented behavior; they are not claimed as independent first-failing cycles. The recovery-autosave fixture correction and the newly added baseline guard were developed together; the initial recovery failure was a fixture error, not proof of the promotion bug.

## Native save trap investigation

Ordinary native `.saveOperation` exposed a SIGTRAP after the synchronous write and reconciliation had returned. A passing retry/minimal probe was not accepted as a resolution. Independent crash-report inspection found the same stack in 16 reports: background AppKit version preservation called the main-actor-inherited Objective-C thunk for `FieldnotesDocument.preservesVersions`, which asserted the executor. The constant class policies and asynchronous-write policy are now explicitly `nonisolated`; state/UI stay on MainActor. See [task-7-diagnostic.md](task-7-diagnostic.md) for exact report path and stack.

Temporary signal handlers, exception handlers, tracing, probe tests, and window/debug timing experiments were removed. The coordinator's initiating-presenter exclusion is retained for its correct coordination semantics; it is **not** attributed as the trap fix. Save-read deferral is lifecycle protection rather than a timing workaround.

## Changed files / self-review

- `Sources/FieldnotesApp/Documents/{ExternalChangeCoordinator,ConflictModel,ConflictView}.swift`: coordinated reader, exact conflict/review models, native comparison and confirmation.
- `Sources/FieldnotesApp/Documents/{FieldnotesDocument,DocumentState,DocumentView,DocumentWindowController}.swift`: native lifecycle, guarded saves, state transitions/selection mapping, UI wiring and existing window geometry.
- `Sources/FieldnotesCore/Workspace.swift`: bounded file-reference URL ancestor discovery.
- `Tests/FieldnotesAppTests/{ExternalChangeTests,WorkspaceCoreTests}.swift`: actual native callbacks/save operations, real disk reads/writes, delayed read fixtures, bounded-traversal regression.
- This report, diagnostic report, and selected RED/GREEN logs.

Reviewed Task 6 scope/context refresh hooks, exact-byte baseline behavior, save snapshot promotion, and bridge revision semantics. Existing asset/security, workspace, bridge, and document tests all pass in the full gate. No ledger changes, reset, clean, or stash operations were performed.

## Limits

- Cursor mapping is a common-prefix/suffix changed-span mapping, not a full semantic diff; it clamps within changed text.
- Comparison/merge confirmation is native SwiftUI; model/controller actions are tested, but no automated screen-click test was performed.
- NSFileCoordinator coordinates participating processes. Byte guards also catch demonstrated noncooperating writes before and during temporary output; a process that ignores coordination can still race the final check/atomic-replacement boundary. NSDocument atomic saving and Versions remain enabled.
- Merge text is an explicit user-provided result; no automatic three-way merge algorithm is claimed.
