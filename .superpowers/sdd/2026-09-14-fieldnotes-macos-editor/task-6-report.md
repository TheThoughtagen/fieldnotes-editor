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
