# `@cruciblesoftware/fieldnotes-renderer`

The shared Markdown rendering contract for FIELDNOTES. It turns a document into sanitized HTML plus frontmatter, headings, diagnostics, assets, plain text, and reading metrics. A self-contained browser entry hydrates Mermaid diagrams without a CDN.

## Install

```sh
npm install @cruciblesoftware/fieldnotes-renderer
```

Node.js 24 or newer is required.

## Render a document

```ts
import { renderDocument } from "@cruciblesoftware/fieldnotes-renderer";
import "@cruciblesoftware/fieldnotes-renderer/styles.css";

const document = await renderDocument(source, {
  sourcePath: "/notes/example.md",
  allowRemoteImages: false,
  frontmatterSchema: {
    type: "object",
    required: ["title"],
    properties: { title: { type: "string" } }
  }
});

preview.innerHTML = document.html;
console.log(document.toc, document.diagnostics, document.assets);
```

Rendered HTML is sanitized. Local image references are reported in `assets`; the renderer does not read image files or perform network requests.

## Hydrate Mermaid in a browser

```ts
import {
  hydrateMermaid,
  normalizeRenderedDom
} from "@cruciblesoftware/fieldnotes-renderer/browser";

preview.innerHTML = document.html;
const results = await hydrateMermaid(preview);
const stableHtml = normalizeRenderedDom(preview);
```

The browser entry bundles Mermaid and is designed to work offline. Diagram failures become visible fallback blocks rather than disappearing.

## Conformance corpus

```ts
import { conformanceCases } from "@cruciblesoftware/fieldnotes-renderer/conformance";
```

The published conformance cases contain reviewed Markdown inputs and literal expected results. Consumers can run the corpus to verify that another rendering surface matches FIELDNOTES behavior.

## License

MIT
