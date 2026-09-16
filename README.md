# FIELDNOTES Editor

Public editor and shared renderer for FIELDNOTES documents.

Remote media is disabled by default. The native preference or embedded client's `allowRemoteImages` option enables HTTPS images and narrowly allowlisted video frames.

FIELDNOTES is a local macOS 14 (Sonoma) or newer Markdown editor for Apple Silicon and Intel. App releases use `vX.Y.Z`; the shared renderer has separate `renderer-vX.Y.Z` releases.

## Install and open

After an app release is published:

```sh
brew tap TheThoughtagen/tap
brew install --cask fieldnotes
fieldnotes --help
fieldnotes notes/post.md --schema schema.json --mode source --line 12 --column 3
fieldnotes ./notes
```

Alternatively download the release DMG, drag FIELDNOTES into Applications, and run `/Applications/FIELDNOTES.app/Contents/Resources/bin/fieldnotes`. That wrapper locates the native CLI inside the same app, including through a Homebrew symlink. Opening the same canonical file, including through a symlink, reuses its document window.

From Neovim, `:!fieldnotes %:p --mode preview` opens the current file. Lua can preserve argument boundaries: `vim.system({'fieldnotes', vim.api.nvim_buf_get_name(0), '--mode', 'source', '--line', tostring(vim.api.nvim_win_get_cursor(0)[1])})`.

## Editing

Focus (`⌘1`), Source (`⌘2`), and Preview (`⌘3`) share one text buffer. `⌘\\` cycles them. `⌘P` opens workspace files, `⌘⇧P` opens commands, and `⌘K` searches the workspace. Native Save uses `⌘S`. Untouched UTF-8 files retain their exact bytes; editing does not regenerate Markdown from the preview.

Vim starts enabled; `⌘⇧V` toggles it. See the executable [Vim compatibility matrix](docs/vim-compatibility.md) for the exact supported/adapted scope (54 families, 146 tokens), including native `:w`/`:q` and Markdown HTML-tag text objects. FIELDNOTES does not run Neovim, user Vimscript, plugins, shell commands, arbitrary mappings, buffers, splits, or tabs. Toggling presentation preserves Vim state; toggling Vim itself resets its adapter-local mode.

## Workspaces, schemas, and images

A folder open establishes the workspace; a file open discovers its workspace configuration. Explicit `--schema` wins over discovered schema settings. JSON Schema validates YAML frontmatter and reports diagnostics without rewriting it. Remote schema references are not fetched. A `.fieldnotes.json` (or `.git`) marks the nearest workspace. Configuration accepts only `frontmatterSchema` (relative path) and `localAssetPolicy` (`workspace` or `document-directory`). For example: `{"frontmatterSchema":"schemas/post.json","localAssetPolicy":"workspace"}`. Without an explicit/configured schema, FIELDNOTES discovers `frontmatter.schema.json` between the document and workspace root. Invalid settings produce diagnostics. Schema references cannot escape the workspace.

Paste or drop an image to copy it into the document's sibling `images` directory with meaningful alt text and a safe relative path. An untitled document first asks for a native save location; Cancel leaves it unsaved and creates no image directory. Link-in-place is explicit and limited to approved scope. Focus displays an image until selection enters its Markdown range; Preview uses generation-scoped native resource URLs. Missing or disallowed images show bounded placeholders.

Clean external changes reload automatically. Dirty changes show the base, editor, and disk versions. Choose editor, disk, or merged text, then confirm before saving; neither side is silently overwritten. Canceling a conflict choice preserves the current buffer.

## Privacy and security

Editing and rendering use bundled assets without a server or CDN. Remote media is off by default. **Editor → Toggle Remote Media** controls HTTPS images and sanitized YouTube-nocookie `/embed/` and Vimeo `/video/` frames; enabling it permits those providers to receive network requests. Turn it off to remove remote media. This preference retains the internal `allowRemoteImages` settings key for compatibility.

Schema validation runs the shared Ajv validator in an isolated native JavaScriptCore context with no filesystem or network callbacks; the web view does not enable `unsafe-eval`. The web view uses a nonpersistent data store, sanitized previews, strict Mermaid rendering, a restrictive content policy, typed main-frame bridge messages, and scoped local resource loading. External HTTPS links open in the system browser. Local image paths are canonicalized and checked against document/workspace authority. The release app contains no integration automation transport. Signing keys stay in CI secrets and temporary runner files.

## Build and verify

Use macOS, Xcode 26.2 / Swift 6.2, Node 24, and npm 11.19.0. Swift Testing is locked to 6.2.3. CI pins the Xcode selection and checks the compiler version.

```sh
npm ci
npx playwright install chromium
npm run typecheck
npm test
swift test
scripts/test-app-integration.sh
scripts/bundle-app.sh release
scripts/sign-and-package.sh --verify-unsigned
git diff --check
```

`bundle-app.sh debug` builds for the host. Release builds compile each architecture separately, verify macOS 14 deployment targets, and merge the app and native CLI into universal binaries. `--verify-unsigned` checks the local ad-hoc signature, universal architectures, assets, CLI help, and absence of the integration controller; it does not claim Developer ID signing or notarization.

The app integration suite requires a logged-in macOS GUI session. Its runner builds with `FIELDNOTES_INTEGRATION` in a separate scratch directory, copies an owned temporary app, launches the bundled native CLI, and inspects the real persistent WK/CodeMirror state and native document. Plain `swift test` skips that suite unless `FIELDNOTES_INTEGRATION_APP` points to an instrumented bundle. Browser tests exercise every exported renderer conformance fixture and final sanitized Mermaid SVG. Native tests show and cancel the actual save panel; for accepted first save, they supply the chosen location and exercise the production authorization, NSDocument Save As, deferred image insertion, and resource-generation transition. The remote macOS Save button itself requires manual UI verification; it is not claimed as automated coverage.

## Release prerequisites

App CI runs on every push and pull request. A `vX.Y.Z` tag reruns the full gate. Configure these repository secrets before tagging; missing values fail the release job:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID` | Developer ID Application signing identity |
| `SIGNING_CERTIFICATE` | Base64 PKCS#12 certificate plus private key |
| `SIGNING_PASSWORD` | PKCS#12 password |
| `NOTARY_PRIVATE_KEY` | Apple App Store Connect API `.p8` contents |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER` | API issuer UUID |
| `TAP_TOKEN` | Token with contents, pull requests, and commit-status write access in `TheThoughtagen/homebrew-tap` |

Apple Developer ID membership, valid notarization access, repository release permissions, and an initialized public tap default branch are required. Enable immutable GitHub releases before publishing. Initialize an empty tap through separately reviewed repository setup; the release workflow does not bootstrap or push directly to its default branch.

The signing script signs the native `Contents/MacOS/fieldnotes` executable first, then the app with Hardened Runtime and no `get-task-allow`. It submits the DMG to Apple, staples and validates the ticket, assesses Gatekeeper, and only then computes the checksum. The workflow verifies the mounted app and CLI, publishes the versioned DMG and checksum, and creates a cask update PR only after checking the published immutable release. Cask audit/install/CLI-open/uninstall run in CI; the tap PR still requires independent review before merge. Credentialed steps cannot be validated by an unsigned local build.
