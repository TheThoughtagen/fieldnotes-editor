# Task 6 report — safe Markdown image workflows

## Result

Implemented native-scoped local image loading, coordinated image imports, explicit link-in-place, unsaved-document save/resume, Focus image widgets, and Preview image resolution without broadening WebKit file read access.

## RED evidence

- `swift test --filter ImageImporterTests`
  - Failed at compile time because `ImageImporter`, `ResourceResolver`, `ResourceError`, and the resource scope did not exist.
- `npm test --workspace packages/editor-web -- images.test.ts`
  - Failed because `packages/editor-web/src/images.ts` did not exist. The simultaneous smoke timeout was caused by the Vite error overlay from that missing module.
- `npx vitest run test/images.test.ts`
  - After the initial module implementation, the integration test failed because `createEditor` had not wired Focus widgets or Preview rewriting.
- `swift test --filter saveAsRefreshesResourceRootAndInvalidatesOldGeneration`
  - Failed because `EditorSession.refreshDocumentLocation` did not exist.
- First full `npm test --workspace packages/editor-web`
  - 212 passed and 2 Preview conformance tests failed because their old expectation removed all local `src` attributes. The implementation now intentionally preserves safe local images through the custom resource policy. The expected DOM was updated to use the same public policy transformation while still removing blocked remote sources.

## GREEN evidence

- `swift test --filter ImageImporterTests`
  - 9 tests passed after adding the document-directory link diagnostic case.
- `npx vitest run test/images.test.ts`
  - 7 tests passed: widget/source reveal, widget selection, deletion/undo, safe resource URLs, bounded loading/error UI, editor integration, paste, and Option-drop link-in-place.
- `npm run typecheck --workspace packages/editor-web`
  - Passed.
- `swift test`
  - 66 tests in 7 suites passed.
- `npm test --workspace packages/editor-web`
  - Vite production build passed.
  - 214 browser tests in 9 files passed.
  - `scripts/test-editor-security.mjs` passed.
  - `scripts/test-offline-bundle.mjs` passed.
  - Vite retained its existing advisory that the single bundle exceeds 800 kB; this is not a test failure.
- `git diff --check`
  - Passed.

## Changes

- Added `ImageImporter` with native file coordination, filesystem-safe names, non-overwriting `-2` collision suffixes, byte imports, and canonical destination containment.
- Added `ResourceSchemeHandler` for `fieldnotes-resource:`. Requests carry the active generation and a relative path; native state supplies the document base and allowed policy root. Resolution canonicalizes symlinks, rejects stale generations, unsupported schemes, escaping paths, missing files, and files above 50 MB.
- Registered only the custom resource scheme on the existing nonpersistent WebKit configuration. The editor HTML still loads with bundle-only `loadFileURL` read access.
- Added a closed, revision- and generation-scoped image import bridge with bounded metadata/base64 payloads. Native replies expose relative Markdown paths rather than filesystem roots.
- Unsaved imports open a native `NSSavePanel`, save through `NSDocument`, refresh the workspace/document scope, and resume the pending import. Cancellation creates neither an image nor an editor edit.
- Save-as refreshes the active workspace/document context and invalidates prior resource generations.
- Added a main-frame-only native alt-text prompt for actual WKWebView use.
- Added paste and drop imports. Copy is the default; Option-drop requests link-in-place when the native file URL is present. A document-directory link receives a publication diagnostic.
- Added Focus widgets that keep exact Markdown in the single CodeMirror buffer, reveal it when selection enters the source range, map widget clicks back to that range, show bounded loading/error states, and preserve Vim/history behavior.
- Preview rewrites local images through the custom scheme. Remote images are disabled by default; an explicit editor option enables HTTPS images. CSP allows only the narrow custom scheme, data, same-origin assets, and HTTPS image loads while `connect-src` remains `none`.

## Self-review and limits

- The native authority/generation is opaque; the URL query contains the document-relative asset path so missing-image UI can retain the unresolved path. Native canonicalization remains the authorization boundary.
- Link-in-place depends on WebKit providing `text/uri-list` for a filesystem drag. If it is absent, the drop safely falls back to the normal copied-byte import.
- Browser tests cover the DOM events and native bridge contracts; there is no automated end-to-end test that drives the macOS save panel or a Finder drag into a packaged app.
- Local resource responses are capped at 50 MB. Image import data is capped at 20 MB after decoding.

## Review remediation round 1

### RED evidence

- The independent spec and quality reviews found 14 concrete gaps at `1ff32d2`: untitled imports could not enter the native save flow; Focus widgets retained stale generation URLs; path checks allowed symlink and check/use races; Markdown URL decoding and image parsing were incomplete; failed resources/imports lacked visible state; asynchronous imports did not retain revision, context, or insertion identity; document moves and the remote-media preference were not wired through production; browser-supplied file URLs could request native copies; size/concurrency/cancellation limits were incomplete; and drops used the old selection.
- Focused regressions initially reproduced those failures. Examples included an outside-root `images` symlink accepting a write, a deterministic parent swap between authorization and open, a forged `image/png` payload reaching import, stale Focus DOM after a generation change, title/reference/code image syntax producing wrong ranges, a deferred paste replacing a later selection, and teardown resuming a save into an asset write.
- The first full browser gate after the fixes had 221 passing tests and one failure in the `unsafe-html` Preview conformance fixture: generation-zero local images made a bundle-relative request and changed error UI asynchronously (`children: 5` versus `4`). Local resource URLs are now withheld until a positive native generation exists, producing deterministic blocked UI without an ambient web-relative read.

### GREEN evidence

- `swift test --filter ImageImporterTests`: 20/20 passed. This includes fresh untitled production setup, save cancellation, actual `NSDocument.save(... .saveAsOperation)` first-save/resume with exactly one context transition, native Option-link selection, presented-item moves, remote preference replay, forged MIME rejection, teardown cancellation, encoded paths, SVG resource MIME, static symlinks, and deterministic descriptor race tests.
- `npm run test --workspace @thethoughtagen/fieldnotes-editor-web`: production build and 222/222 browser tests passed; editor security and offline-bundle checks passed.
- `swift test`: 77 tests in 7 suites passed.
- `npm test`: renderer build and 101/101 renderer tests passed; editor production build and 222/222 browser tests passed; security/offline scripts and 3/3 Vim documentation tests passed.
- `npm run typecheck`: renderer and editor TypeScript checks passed after the required renderer rebuild.
- `git diff --check`: passed.

### Changes and security review

- Untitled documents now install a generation-scoped context without read authority. A pending import invokes the native save panel, authorizes only the expected first-save URL transition, saves through `NSDocument`, refreshes the native workspace context, and resumes only if document, revision, generation, and operation identity remain valid. Cancellation and bridge teardown cannot write an asset or edit text.
- Native imports accept bounded validated image bytes. The unused browser-controlled copy-by-path branch was removed. Link-in-place accepts only a root-contained file URL or a file chosen by the native open panel; it never copies that source. Browser `File.size` is checked before allocation, native data is limited and decoded off the main actor, one import may be in flight, and errors reach a visible bounded diagnostic.
- `SecureFileIO` anchors reads and writes to directory descriptors, walks components with `openat` and `O_NOFOLLOW`, validates the opened regular object, bounds streaming reads, creates the `images` directory relative to the authorized root, and writes collision names with `O_EXCL`. Resource work runs off the main actor with an eight-request cap and cancellation; only extension-identified image resources are served, including SVG with `image/svg+xml`.
- Focus image ranges now come from the shared CodeMirror Markdown syntax tree, including titles, balanced destinations, escaped alt text, and references while excluding code. Widgets capture immutable generation/policy values, reveal exact source on selection, and expose bounded loading/error states. Preview produces alt-and-path placeholders and diagnostics for blocked or failed resources.
- Paste retains and maps its original replacement range; edits touching that range cancel insertion. Drop captures the document coordinate instead of replacing an unrelated selection. Native replies carry document, revision, and generation identity, with only the explicitly authorized first-save generation transition accepted.
- Save, Save As, presented-item moves, and remote-image preference changes refresh or replay native context without replacing the single CodeMirror buffer. Remote images remain disabled by default and the app menu exposes the persisted native control; enabled media remains HTTPS-only.

### Remaining platform validation

- Finder-to-WKWebView URI-list behavior varies by WebKit/macOS. When no trusted URI is present, Option-drop now opens the native file picker, so the production workflow remains available without relying on the browser drag payload. Packaged-app panel and Finder automation remains part of the later native end-to-end harness.
- The custom resource URL uses a generation authority and a native-validated relative-path query. It does not expose an unrestricted filesystem root or broaden `loadFileURL` read access.
