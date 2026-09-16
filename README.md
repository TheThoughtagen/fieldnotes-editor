# FIELDNOTES Editor

Public editor and shared renderer for FIELDNOTES documents.

Remote media is disabled by default. The native preference or embedded client's `allowRemoteImages` option enables HTTPS images and narrowly allowlisted video frames.

FIELDNOTES is a local macOS 14 (Sonoma) or newer Markdown editor for Apple Silicon and Intel. App releases use `vX.Y.Z`; the shared renderer has separate `renderer-vX.Y.Z` releases.

## Install and open

Unsigned previews are distributed separately from signed app releases. Download the `FIELDNOTES-X.Y.Z-unsigned-preview-universal.dmg` and matching `.sha256` from a preview release, when available, or the **FIELDNOTES-unsigned-preview-universal** artifact of a successful App CI run. CI artifacts require a GitHub login. Verify the download with `shasum -a 256 -c FIELDNOTES-X.Y.Z-unsigned-preview-universal.sha256`, open the DMG, and drag FIELDNOTES into Applications.

Previews are **not Developer ID signed or notarized**. macOS may block them. If you trust the download, attempt to open the copied app, then use **System Settings → Privacy & Security → Open Anyway** and follow the prompts ([Apple’s instructions](https://support.apple.com/en-us/102445)). Do not disable Gatekeeper globally. Previews support macOS 14+ on Apple Silicon and Intel and do not install through Homebrew.

Homebrew installation becomes available after a signed, notarized app release and its reviewed cask update are published:

```sh
brew tap TheThoughtagen/tap
brew install --cask fieldnotes
fieldnotes --help
fieldnotes notes/post.md --schema schema.json --mode source --line 12 --column 3
fieldnotes ./notes
```

For signed releases, alternatively download the release DMG, drag FIELDNOTES into Applications, and run `/Applications/FIELDNOTES.app/Contents/Resources/bin/fieldnotes`. That wrapper locates the native CLI inside the same app, including through a Homebrew symlink. Opening the same canonical file, including through a symlink, reuses its document window.

From Neovim, `:!fieldnotes %:p --mode preview` opens the current file. Lua can preserve argument boundaries: `vim.system({'fieldnotes', vim.api.nvim_buf_get_name(0), '--mode', 'source', '--line', tostring(vim.api.nvim_win_get_cursor(0)[1])})`.

## Editing

Focus (`⌘1`), Source (`⌘2`), and Preview (`⌘3`) share one text buffer. `⌘\\` cycles them. `⌘P` opens workspace files, `⌘⇧P` opens commands, and `⌘K` searches the workspace. Native Save uses `⌘S`. Untouched UTF-8 files retain their exact bytes; editing does not regenerate Markdown from the preview.

**Editor → Color Theme…**, **Settings → Choose Color Theme…**, and the command palette open a searchable picker with six curated palettes, live preview, and VS Code JSON/JSONC import. Arrow keys preview; Return applies; Escape cancels. The choice is saved app-wide and updates open and future windows; System follows macOS appearance. Theme changes preserve the document, selection, undo history, Vim state, and scroll position. See [color themes and import compatibility](docs/color-themes.md).

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

The committed icon master is `packaging/AppIcon.png` (1024 × 1024 PNG). Rebuild its macOS icon family with `scripts/build-app-icon.sh` (or supply another 1024 × 1024 PNG as the first argument); the script uses macOS `sips` and `iconutil` and produces `packaging/AppIcon.icns`.

To create an unsigned preview locally:

```sh
APP_VERSION=0.1.0 scripts/bundle-app.sh release
APP_VERSION=0.1.0 scripts/package-unsigned-preview.sh
```

The packager requires the requested version to match both bundle version fields, verifies universal binaries and local ad-hoc signatures, and writes `build/FIELDNOTES-0.1.0-unsigned-preview-universal.dmg` and `.sha256`. It includes an Applications shortcut and installation instructions. App CI produces these same preview artifacts without signing credentials; it does not publish a GitHub release or a Homebrew cask. The signed release workflow remains separate and requires all credentials below.

`bundle-app.sh debug` builds for the host. `APP_VERSION` defaults to the source plist's short version and sets both bundle version fields before signing. Release builds compile each architecture separately, verify macOS 14 deployment targets, and merge the app and native CLI into universal binaries. `--verify-unsigned` checks the local ad-hoc signature, universal architectures, assets, CLI help, and absence of the integration controller; it does not claim Developer ID signing or notarization.

The app integration suite requires a logged-in macOS GUI session. Its runner builds with `FIELDNOTES_INTEGRATION` in a separate scratch directory, copies an owned temporary app, launches the bundled native CLI, and inspects the real persistent WK/CodeMirror state and native document. Plain `swift test` skips that suite unless `FIELDNOTES_INTEGRATION_APP` points to an instrumented bundle. Browser tests exercise every exported renderer conformance fixture and final sanitized Mermaid SVG. Native tests show and cancel the actual save panel; for accepted first save, they supply the chosen location and exercise the production authorization, NSDocument Save As, deferred image insertion, and resource-generation transition. The remote macOS Save button itself requires manual UI verification; it is not claimed as automated coverage.

## Release prerequisites

App CI runs on every push and pull request. A `vX.Y.Z` tag reruns the full gate. The signed release path requires paid Apple Developer Program membership, a **Developer ID Application** certificate with its private key (not Apple Development or Developer ID Installer), and notarization access. The account holder can create the certificate in [Apple Certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/). Export the identity and private key together from Keychain Access as a password-protected `.p12`.

In App Store Connect → Users and Access → Integrations, create/download a notarization-capable API key. A **team API key** with Developer access is recommended: record its key ID and issuer UUID and securely retain the `.p8` (downloadable once). Individual API keys are also supported by current Xcode; omit the issuer for those keys. The Apple team ID comes from Developer account membership details; it is distinct from the API issuer UUID.

Configure these repository secrets before tagging; missing required values fail closed:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID` | Full `Developer ID Application: Name (TEAMID)` identity |
| `APPLE_TEAM_ID` | Expected 10-character Apple Developer team ID |
| `SIGNING_CERTIFICATE` | Base64 PKCS#12 certificate plus private key |
| `SIGNING_PASSWORD` | Nonempty PKCS#12 password |
| `NOTARY_PRIVATE_KEY` | App Store Connect API `.p8` contents |
| `NOTARY_KEY_ID` | API key ID |
| `NOTARY_ISSUER` | Team API issuer UUID; empty for individual API keys |

Keep the `.p12` and `.p8` outside this checkout, such as in a private directory under your home folder. Authenticate `gh` for this repository, then validate the local files with the helper (the certificate password is prompted with hidden input):

```sh
python3 scripts/configure-release-secrets.py \
  --repo TheThoughtagen/fieldnotes-editor \
  --certificate "$HOME/.private/apple/developer-id.p12" \
  --notary-key "$HOME/.private/apple/AuthKey_KEYID.p8" \
  --developer-id 'Developer ID Application: Your Name (TEAMID1234)' \
  --team-id TEAMID1234 --key-id YOURKEYID1 \
  --issuer 00000000-0000-0000-0000-000000000000
```

Replace every example value with your account details. This validates file formats only. Repeat with `--upload` to set repository secrets through stdin; no secret is placed in command arguments or written into the repository. Omit `--issuer` for an individual key. Upload replaces all listed secrets, including clearing a previous issuer when switching to an individual key. The helper does not create a tag or publish a release. Keep credential exports private and do not paste passwords or private keys into chat, issue descriptions, or workflow logs.

Enable immutable GitHub releases in repository settings before publication. Before creating a release tag, verify the live setting with your repository administrator's local `gh` authentication:

```sh
GITHUB_REPOSITORY=TheThoughtagen/fieldnotes-editor scripts/check-release-policy.sh
```

This endpoint requires Administration(read), which the workflow's built-in token cannot obtain. CI uses its built-in token to publish, then requires the resulting release's `immutable` property to be true. That postcondition detects configuration drift, but cannot prevent a mutable publication if someone disables the setting after the local preflight. Keep the repository policy enabled. To release a reviewed commit, run `git tag vX.Y.Z <reviewed-commit>` and `git push origin vX.Y.Z`. To retry an existing tag, rerun its failed workflow or use `gh workflow run release-app.yml --ref vX.Y.Z`; branch dispatches are rejected. Never move a published tag. A failed run that created a draft may require deleting that unpublished draft before retrying; published immutable releases cannot be replaced.

The signing script requires `APP_VERSION` to match both bundle version fields before signing. It resolves the exact Developer ID identity only in a temporary keychain, signs the native CLI and app with Hardened Runtime and timestamps, and checks their authority and team. It submits an app ZIP, requires a structured `Accepted` response, staples and validates the app, then creates and signs a DMG containing that app and the Applications shortcut. It notarizes and staples the DMG separately, verifies Gatekeeper for both, and computes the checksum of the final stapled bytes. Each notary wait is limited to 15 minutes; submission IDs, structured responses, and Apple logs are retained as workflow artifacts on failures as well as successes. A timeout does not cancel Apple's processing; inspect the report before retrying. CI removes temporary signing credentials even after failure.

Homebrew is optional and cannot block publishing the signed app. Set repository variable `ENABLE_HOMEBREW=true` only after initializing and reviewing the public `TheThoughtagen/homebrew-tap` default branch and adding `TAP_TOKEN` with contents, pull requests, and commit-status write access for that tap. The separate Homebrew job checks the published immutable release, runs cask audit/install/CLI-open/uninstall checks, and opens a cask PR for independent review. Leave the variable unset while the tap is empty or its token is unavailable.

The local release tests use command stubs to verify rejection, timeout, ordering, and policy behavior. They do **not** validate real Apple credentials, signatures, notarization, or Gatekeeper acceptance. A successful credentialed workflow and mounted distribution checks are required before claiming a signed, notarized release.
