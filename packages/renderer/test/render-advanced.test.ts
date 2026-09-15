import { describe, expect, it } from "vitest";
import { renderDocument } from "../src/index.js";

describe("advanced Markdown rendering", () => {
  it("renders accessible footnotes with backreferences", async () => {
    const result = await renderDocument("A claim[^source].\n\n[^source]: Supporting evidence.\n");

    expect(result.html).toContain('data-footnote-ref');
    expect(result.html).toContain('class="data-footnote-backref"');
    expect(result.html).toContain("Supporting evidence.");
  });

  it("renders inline and display math through KaTeX", async () => {
    const result = await renderDocument("Inline $x^2$ here.\n\n$$\ny = mx + b\n$$\n");

    expect(result.html).toContain('class="katex"');
    expect(result.html).toContain('class="katex-display"');
    expect(result.html).not.toContain("$x^2$");
  });

  it("highlights language fences and marks requested one-based lines", async () => {
    const result = await renderDocument("```javascript {1,3-4}\nconst one = 1;\nconst two = 2;\nconst three = 3;\nconst four = 4;\n```\n");

    expect(result.html).toContain('class="hljs language-javascript"');
    const marked = result.html.match(/data-highlighted-line="true"/g) ?? [];
    expect(marked).toHaveLength(3);
    expect(result.diagnostics).not.toContainEqual(expect.objectContaining({ code: "code.highlight-range" }));
  });

  it.each(["{3-1}", "{0,2}", "{1,nope}"])(
    "diagnoses malformed highlight metadata %s and renders ordinary code",
    async meta => {
      const result = await renderDocument(`\`\`\`javascript ${meta}\nconst value = 1;\n\`\`\`\n`);

      expect(result.html).toContain('class="hljs language-javascript"');
      expect(result.html).not.toContain("data-highlighted-line");
      expect(result.diagnostics).toContainEqual(expect.objectContaining({
        code: "code.highlight-range",
        severity: "warning"
      }));
    }
  );

  it.each([
    "{4}",
    "{1-999999999}",
    "{9007199254740992}",
    "{999999999999999999999999999999999999999999999999999999999999}"
  ])("rejects out-of-line or unsafe highlight metadata %s before expansion", async meta => {
    const result = await renderDocument(`\`\`\`javascript ${meta}\none();\ntwo();\nthree();\n\`\`\`\n`);

    expect(result.html).not.toContain("data-highlighted-line");
    expect(result.diagnostics).toContainEqual(expect.objectContaining({
      code: "code.highlight-range",
      severity: "warning"
    }));
  });

  it("accepts a range ending on the actual last code line", async () => {
    const result = await renderDocument("```javascript {2-3}\none();\ntwo();\nthree();\n```\n");

    expect(result.html.match(/data-highlighted-line="true"/g)).toHaveLength(2);
    expect(result.diagnostics).not.toContainEqual(expect.objectContaining({ code: "code.highlight-range" }));
  });

  it("turns titled images into figures without changing asset metadata", async () => {
    const titled = await renderDocument('![Panel](images/panel.png "Gateway status")');
    const untitled = await renderDocument("![Panel](images/panel.png)");

    expect(titled.html).toContain("<figure>");
    expect(titled.html).toContain("<figcaption>Gateway status</figcaption>");
    expect(titled.assets[0]).toMatchObject({ source: "images/panel.png", title: "Gateway status" });
    expect(untitled.html).toBe('<p><img alt="Panel" src="images/panel.png"></p>');
    expect(untitled.html).not.toContain("<figure>");
  });

  it("uses and preserves a safe explicit anchor for the following heading", async () => {
    const result = await renderDocument('<a id="stable-id"></a>\n\n## Visible *heading*\n');

    expect(result.html).toContain('<a id="stable-id"></a>');
    expect(result.html).toContain('<h2 id="stable-id">Visible <em>heading</em></h2>');
    expect(result.toc).toEqual([{ depth: 2, id: "stable-id", text: "Visible heading", children: [] }]);
  });

  it("rejects invalid explicit anchors and diagnoses duplicate explicit IDs", async () => {
    const invalid = await renderDocument('<a id="1 bad"></a>\n\n## Safe fallback\n');
    const duplicate = await renderDocument('<a id="same"></a>\n\n## One\n\n<a id="same"></a>\n\n## Two\n');

    expect(invalid.html).not.toContain("1 bad");
    expect(invalid.html).toContain('<h2 id="safe-fallback">');
    expect(invalid.diagnostics).toContainEqual(expect.objectContaining({ code: "heading.invalid-explicit-id" }));
    expect(duplicate.html.match(/id="same"/g)).toHaveLength(2);
    expect(duplicate.html).toContain('<h2 id="two">Two</h2>');
    expect(duplicate.diagnostics).toContainEqual(expect.objectContaining({ code: "heading.duplicate-id" }));
  });

  it("uses visible heading text rather than raw inline HTML source", async () => {
    const result = await renderDocument("## Hello <span>visible</span> world\n");

    expect(result.toc[0]).toMatchObject({ id: "hello-visible-world", text: "Hello visible world" });
  });

  it("keeps Mermaid source inert for trusted browser hydration", async () => {
    const result = await renderDocument("```mermaid\nflowchart LR\nA-->B\n```\n");

    expect(result.html).toContain('class="fieldnotes-mermaid"');
    expect(result.html).toMatch(/data-fieldnotes-mermaid="sha256:[a-f0-9]{64}"/u);
    expect(result.html).toContain("flowchart LR");
    expect(result.html).not.toContain("<svg");
    expect(result.plainText).toBe("");
  });
});
