# Color themes

Choose **Editor → Color Theme…**, **Settings → Choose Color Theme…**, or **Color Theme…** in the command palette. Search by name, Light/Dark, or Imported. Arrow keys preview a palette in every open window. Return or Apply Theme saves it; Escape, Cancel, or closing the picker restores the saved theme. New windows inherit the saved selection. System follows macOS appearance.

Linen, Midnight, Sandstone, Glacier, Forest After Dark, and Ink & Iris are bundled palettes. Import JSON adds a removable palette to the catalog; removing an active imported theme returns to System. Bundled palettes cannot be removed. Importing and removing catalog entries are retained even if you cancel the color preview.

## Import compatibility

Choose a standalone VS Code JSON or JSONC color theme file with a `name`, optional `type` (`light`, `dark`, `hc`, `hcLight`; defaults to dark), a `colors` object and optional inline `tokenColors` array. JSONC comments and trailing commas are supported. `hc`/`hcLight` select dark/light native controls; importing them does not certify accessibility contrast.

Colors must be hexadecimal `#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA`. Missing values fall back to Linen or Midnight. Imported contrast depends on the file's colors. These UI keys are mapped:

| VS Code key | FIELDNOTES surface |
| --- | --- |
| `editor.background`, `editor.foreground` | Paper, text |
| `editorGroupHeader.tabsBackground`, `editorWidget.background` | Secondary surfaces |
| `descriptionForeground`, `editorWidget.border`, `focusBorder` | Muted text, borders, accent |
| `editor.selectionBackground`, `editor.lineHighlightBackground` | Selection, active line |
| `editorCursor.foreground` | Caret |
| `editorGutter.background`, `editorLineNumber.foreground` | Source gutter |
| `textLink.foreground`, `textCodeBlock.background` | Links, code surfaces |
| `editorError.foreground`, `inputValidation.errorBackground` | Diagnostic text, background |

For `tokenColors`, supported scopes are `comment`, `keyword`, `storage`, `keyword.operator`, `string`, `constant.numeric`, `entity.name.type`, `support.type`, `entity.name.function`, `support.function`, `variable`, `invalid`, `markup.heading`, and `markup.underline.link`. Dot-qualified descendants match their category. Scopes may be comma-separated strings or arrays; later matching rules win. Operator matching takes precedence over general keyword matching within a rule. FIELDNOTES uses CodeMirror categories rather than a TextMate grammar; compound selectors, exclusions, font styles, semantic-token rules and unmatched scopes are ignored. Embedded syntax coloring depends on the editor's existing language support. Preview code is plain semantic renderer output.

Include chains, external `.tmTheme` references and extension packages are unsupported. Export or combine them into a standalone JSON file first. Import is data-only: no CSS, JavaScript, URLs, other files or theme network requests are executed or loaded. The chosen regular file is bounded to 1 MiB, 2,048 UI colors and 4,096 token rules; up to 64 normalized imports are stored in app-owned preferences. Errors preserve the current theme.

Mermaid diagrams keep their renderer-provided colors on a stable light surface. Theme changes do not rewrite Markdown, renderer HTML, or SVG.
