import { describe, expect, it } from "vitest";
import { hydrateMermaid, normalizeRenderedDom } from "../src/browser.js";

const digest = "c18237e0a535bdb73d9c241d24e7905bd72b7e64ca3ece4b5c241eb4fd8c7546";

describe("trusted Mermaid hydration", () => {
  it("renders verified placeholders deterministically in independent containers", async () => {
    const first = document.createElement("div");
    const second = document.createElement("div");
    for (const container of [first, second]) {
      container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre>`;
      document.body.append(container);
    }

    const firstResult = await hydrateMermaid(first);
    const secondResult = await hydrateMermaid(second);

    expect(firstResult).toEqual([expect.objectContaining({ status: "rendered" })]);
    expect(secondResult).toEqual([expect.objectContaining({ status: "rendered" })]);
    expect(normalizeRenderedDom(first)).toBe(normalizeRenderedDom(second));
    expect(first.querySelector("svg")).not.toBeNull();
    expect(first.querySelector("script, foreignObject")).toBeNull();
  });

  it("keeps source inert and reports an error when the digest is invalid", async () => {
    const container = document.createElement("div");
    container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${"0".repeat(64)}">graph TD; A--&gt;B</pre>`;

    const results = await hydrateMermaid(container);

    expect(results).toEqual([expect.objectContaining({ status: "error", code: "digest-mismatch" })]);
    expect(container.querySelector("pre.fieldnotes-mermaid-error")?.textContent).toBe("graph TD; A-->B");
    expect(container.querySelector("svg, script")).toBeNull();
  });

  it("strictly sanitizes SVG returned by the renderer", async () => {
    const container = document.createElement("div");
    container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre>`;
    const renderer = {
      initialize: (config: object) => expect(config).toMatchObject({ securityLevel: "strict" }),
      render: async () => ({
        svg: `<svg id="diagram"><style>.bad{fill:url(https://evil.example/a)}</style><script>alert(1)</script><foreignObject>bad</foreignObject><g id="node" onclick="bad()" style="fill:url(https://evil.example/a)"><a href="https://evil.example"><path fill="url(#node)"></path></a></g></svg>`
      })
    };

    const results = await hydrateMermaid(container, { renderer });

    expect(results).toEqual([expect.objectContaining({ status: "rendered" })]);
    expect(container.querySelector("script, foreignObject, [onclick]")).toBeNull();
    expect(container.querySelector("a")?.hasAttribute("href")).toBe(false);
    expect(container.querySelector("g")?.hasAttribute("style")).toBe(false);
    expect(container.querySelector("style")).toBeNull();
    expect(container.querySelector("path")?.getAttribute("fill")).toMatch(/^url\(#[^)]+\)$/u);
  });

  it("retains an escaped error node after Mermaid parse failure", async () => {
    const container = document.createElement("div");
    container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre>`;
    const renderer = {
      initialize: () => undefined,
      render: async () => { throw new Error("parse failed"); }
    };

    const results = await hydrateMermaid(container, { renderer });

    expect(results).toEqual([expect.objectContaining({ status: "error", code: "render-failed" })]);
    expect(container.querySelector("pre.fieldnotes-mermaid-error")?.textContent).toBe("graph TD; A-->B");
  });
});
