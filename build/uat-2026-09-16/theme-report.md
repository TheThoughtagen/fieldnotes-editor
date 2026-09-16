# UAT theme integration — 2026-09-16

Implemented persistent Editor > Appearance > System / Light / Dark and a real Settings appearance picker. The app-level NSAppearance override propagates to native windows/sheets and WKWebView. System clears the override and inherits macOS appearance. Theme changes send no bridge message, refresh no snapshot, and recreate no editor.

The consumer shell now has restrained light/dark tokens, a 720px prose column (16px native system font) for Focus/Preview, compact 13px monospace Source, adaptive syntax colors, selection/caret/gutters, image/diagnostic/palette/search surfaces and native secondary status styling. Focus decorations cover entire code/quote blocks plus emphasis, strong, links and inline code. YAML metadata stays compact and no longer becomes a Setext heading. Actual links retain their underline; headings do not. Mixed task/plain Preview lists retain normal bullets.

Shared renderer source, generated HTML, fixtures and Mermaid SVG are unchanged. Mermaid retains its internal default colors on a stable light panel, including in Dark mode; this avoids recoloring or regenerating diagrams during appearance changes. Preview code retains the renderer's plain semantic code output; syntax coloring applies in the editing surface.

## Evidence

- `theme-red-web.log`: computed-style regression fails against original styling (monospace Focus).
- `theme-typecheck.log`: TypeScript gate passed.
- `theme-full-web.log`: all 101 renderer and 239 editor tests passed, including conformance; Vim/docs, security/offline, release and launcher checks passed.
- `theme-full-native.log`: all 113 Swift tests pass, including two new appearance tests.
- `theme-native-appearance.log`: random UserDefaults suite persistence and invalid-value fallback; two live native NSWindows with actual WKWebViews follow Light → Dark → Light via `matchMedia`; a future window inherits Dark; System clears override. The page identity and textarea survive. Tests change only their own process appearance, not OS preferences or the production app.
- `theme-visual.log`, `theme-browser-measurements.json`: actual Chromium light/dark media emulation, all three modes, foreground and Source syntax contrast >=4.5:1; same EditorView, Vim adapter, text, selection and undo/redo history; scroll remains at 400px through live appearance change.
- `theme-{light,dark}-{focus,source,preview}.png`: screenshots visually inspected, including headings, prose/links, quote, mixed list, table, code and rendered Mermaid. Fixture has valid YAML and no ordinary validation banner.
- `theme-{light,dark}-palette.png`: command palette screenshots.

The reproducible browser capture harness is `scripts/uat/theme-visual.mjs` (requires editor Vite dev server on 127.0.0.1:4178). Native tests are in `Tests/FieldnotesAppTests/AppearanceTests.swift`. Browser regression tests are in `packages/editor-web/test/theme.test.ts`; the heading Source assertion now correctly compares against Source body size after intentional compact typography.

## Practical limits

System inheritance is verified by clearing native overrides; the tests intentionally do not change the user's macOS appearance setting. Native testing uses real WKWebView media queries in the test process, while full Markdown screenshots/state preservation use Chromium. No OS-wide visual theme flip or manual Settings/menu clicking is claimed. Manual UAT after safe restart remains pending. Production app PID 54379 was not quit/relaunched and UAT documents were not modified. No push, tag, signing/notarization or publishing was performed.

## Final artifact

Universal release bundle built successfully at `build/FIELDNOTES.app`; `theme-universal-build.log` records completion. `theme-unsigned-verify.log` confirms arm64 + x86_64 for the app and CLI, valid local ad-hoc signatures, Info.plist and launcher verification. This is an unsigned-development validation, not a notarized release. PID 54379 remained alive after the build/verification. The artifact is ready for independent review and safe user-controlled restart after saving UAT edits.
