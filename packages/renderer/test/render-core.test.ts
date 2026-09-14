import { describe, expect, it } from "vitest";
import { renderDocument } from "../src/index.js";

describe("renderDocument core Markdown", () => {
  it("renders GFM body HTML and builds a nested H2/H3 TOC", async () => {
    const result = await renderDocument(`---
title: Renderer Demo
---
# Title outside the TOC

### Unscoped

## Observe

### Compare

## Observe

#### Supporting detail

| Signal | Meaning |
| --- | --- |
| \`x\` | ~~old~~ [docs](https://example.com) and https://example.test |

- [x] Finished
`, {
      frontmatterSchema: {
        type: "object",
        required: ["title"],
        properties: { title: { type: "string" } },
        additionalProperties: false
      }
    });

    expect(result.toc).toEqual([
      {
        depth: 2,
        id: "observe",
        text: "Observe",
        children: [{ depth: 3, id: "compare", text: "Compare", children: [] }]
      },
      { depth: 2, id: "observe-1", text: "Observe", children: [] }
    ]);
    expect(result.html).toContain('<h1 id="title-outside-the-toc">Title outside the TOC</h1>');
    expect(result.html).toContain('<h3 id="unscoped">Unscoped</h3>');
    expect(result.html).toContain('<h2 id="observe">Observe</h2>');
    expect(result.html).toContain('<h3 id="compare">Compare</h3>');
    expect(result.html).toContain('<h2 id="observe-1">Observe</h2>');
    expect(result.html).toContain('<h4 id="supporting-detail">Supporting detail</h4>');
    expect(result.html).toContain("<table>");
    expect(result.html).toContain("<del>old</del>");
    expect(result.html).toContain('<a href="https://example.com">docs</a>');
    expect(result.html).toContain('<a href="https://example.test">https://example.test</a>');
    expect(result.html).toContain('type="checkbox" checked disabled');
    expect(result.normalizedHtml).toBe(result.html);
    expect(result.frontmatter).toEqual({ title: "Renderer Demo" });
    expect(result.diagnostics).toEqual([]);
    expect(result.assets).toEqual([]);
    expect(result.plainText).toBe(
      "Title outside the TOC Unscoped Observe Compare Observe Supporting detail Signal Meaning old docs and https://example.test Finished"
    );
    expect(result.wordCount).toBe(17);
    expect(result.readingMinutes).toBe(1);
  });

  it("includes schema diagnostics with frontmatter diagnostics", async () => {
    const result = await renderDocument("---\ntitle: 42\n---\nBody\n", {
      frontmatterSchema: {
        type: "object",
        properties: { title: { type: "string" } }
      }
    });

    expect(result.frontmatter).toEqual({ title: 42 });
    expect(result.diagnostics).toEqual([
      expect.objectContaining({ code: "schema.type", severity: "error" })
    ]);
  });
});
