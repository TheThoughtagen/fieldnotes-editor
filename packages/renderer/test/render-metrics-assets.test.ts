import { afterEach, describe, expect, it, vi } from "vitest";
import { renderDocument } from "../src/index.js";

const source = `---
title: Hidden frontmatter words
---

Opening visible prose with [linked words](https://example.com/docs).

## Heading words

- List item words

> Quoted words

![Local alt](images/gateway.png "Local title")

![Remote alt](https://cdn.example.com/status.png "Remote title")

\`inline code words excluded\`

$inline math words excluded$

$$
display math words excluded
$$

\`\`\`text
fenced code words excluded
\`\`\`

\`\`\`mermaid
flowchart LR
  Mermaid --> Source
\`\`\`
`;

afterEach(() => vi.unstubAllGlobals());

describe("visible text metrics", () => {
  it("counts only reader-visible Markdown text", async () => {
    const result = await renderDocument(source);

    expect(result.plainText).toBe(
      "Opening visible prose with linked words. Heading words List item words Quoted words Local alt Remote alt"
    );
    expect(result.wordCount).toBe(17);
    expect(result.readingMinutes).toBe(1);
  });

  it("uses a positive custom reading speed", async () => {
    const result = await renderDocument(source, { wordsPerMinute: 5 });

    expect(result.wordCount).toBe(17);
    expect(result.readingMinutes).toBe(4);
    expect(result.diagnostics).not.toContainEqual(
      expect.objectContaining({ code: "options.words-per-minute" })
    );
  });

  it.each([0, -1, Number.NaN, Number.POSITIVE_INFINITY])(
    "falls back to 220 WPM and diagnoses invalid value %s",
    async wordsPerMinute => {
      const result = await renderDocument(source, { wordsPerMinute });

      expect(result.readingMinutes).toBe(1);
      expect(result.diagnostics).toContainEqual({
        code: "options.words-per-minute",
        message: "wordsPerMinute must be a finite positive number; using 220.",
        severity: "warning"
      });
    }
  );
});

describe("image asset references", () => {
  it("records local and remote images without filesystem or network access", async () => {
    vi.stubGlobal("fetch", () => {
      throw new Error("renderDocument must not fetch remote assets");
    });

    const result = await renderDocument(source, {
      sourcePath: "/workspace/posts/diagnostics/index.md"
    });

    expect(result.assets).toEqual([
      {
        kind: "image",
        source: "images/gateway.png",
        resolvedPath: "/workspace/posts/diagnostics/images/gateway.png",
        remote: false,
        alt: "Local alt",
        title: "Local title"
      },
      {
        kind: "image",
        source: "https://cdn.example.com/status.png",
        remote: true,
        alt: "Remote alt",
        title: "Remote title"
      }
    ]);
  });

  it("retains remote assets when policy disables them and emits a diagnostic", async () => {
    const result = await renderDocument("![Status](http://example.com/status.png)", {
      allowRemoteImages: false
    });

    expect(result.assets).toEqual([{
      kind: "image",
      source: "http://example.com/status.png",
      remote: true,
      alt: "Status"
    }]);
    expect(result.diagnostics).toContainEqual({
      code: "image.remote-disabled",
      message: "Remote image is disabled: http://example.com/status.png",
      severity: "warning"
    });
  });

  it("omits resolvedPath when no source path is supplied", async () => {
    const result = await renderDocument("![Local](../images/local.png)");

    expect(result.assets).toEqual([{
      kind: "image",
      source: "../images/local.png",
      remote: false,
      alt: "Local"
    }]);
  });

  it("discovers reference-style Markdown images", async () => {
    const result = await renderDocument(`![Reference alt][status]

[status]: images/reference.png "Reference title"
`, { sourcePath: "/workspace/post.md" });

    expect(result.assets).toEqual([{
      kind: "image",
      source: "images/reference.png",
      resolvedPath: "/workspace/images/reference.png",
      remote: false,
      alt: "Reference alt",
      title: "Reference title"
    }]);
  });
});
