import { describe, expect, it } from "vitest";
import { hydrateMermaid, normalizeRenderedDom } from "../src/browser.js";

const digest = "c18237e0a535bdb73d9c241d24e7905bd72b7e64ca3ece4b5c241eb4fd8c7546";

describe("trusted Mermaid hydration", () => {
  it("renders verified placeholders deterministically in independent containers", async () => {
    const first = document.createElement("div");
    const second = document.createElement("div");
    for (const container of [first, second]) {
      container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre><pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre>`;
      document.body.append(container);
    }

    const firstResult = await hydrateMermaid(first);
    const secondResult = await hydrateMermaid(second);

    expect(firstResult).toEqual([
      { hash: `sha256:${digest}`, status: "rendered" },
      { hash: `sha256:${digest}`, status: "rendered" }
    ]);
    expect(secondResult).toEqual(firstResult);
    expect(normalizeRenderedDom(first)).toBe(normalizeRenderedDom(second));
    expect(first.querySelectorAll("svg")).toHaveLength(2);
    expect(first.querySelector("script, foreignObject")).toBeNull();
    const ids = [...first.querySelectorAll<SVGElement>("[id]")].map(element => element.id);
    const idSet = new Set(ids);
    const references = [...first.querySelectorAll<SVGElement>("*")].flatMap(element =>
      [...element.attributes].flatMap(attribute => {
        const urls = [...attribute.value.matchAll(/url\(#([^)]+)\)/gu)].map(match => match[1]);
        const fragment = /^(?:href|xlink:href)$/iu.test(attribute.name) && attribute.value.startsWith("#")
          ? [attribute.value.slice(1)]
          : [];
        return [...fragment, ...urls];
      })
    );
    expect(ids).toHaveLength(idSet.size);
    for (const target of references) expect(idSet).toContain(target);
  });

  it("keeps source inert and reports an error when the digest is invalid", async () => {
    const container = document.createElement("div");
    container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${"0".repeat(64)}">graph TD; A--&gt;B</pre>`;

    const results = await hydrateMermaid(container);

    expect(results).toEqual([{
      hash: `sha256:${"0".repeat(64)}`,
      status: "error",
      message: "Mermaid source digest does not match placeholder."
    }]);
    expect(container.querySelector("pre.fieldnotes-mermaid-error")?.textContent).toBe("graph TD; A-->B");
    expect(container.querySelector("svg, script")).toBeNull();
  });

  it("strictly sanitizes SVG returned by the renderer", async () => {
    const container = document.createElement("div");
    container.innerHTML = `<pre class="fieldnotes-mermaid" data-fieldnotes-mermaid="sha256:${digest}">graph TD; A--&gt;B</pre>`;
    const renderer = {
      initialize: (config: object) => expect(config).toMatchObject({ securityLevel: "strict" }),
      render: async () => ({
        svg: `<svg id="diagram"><style>@import "https://evil.example/a.css";.safe{fill:url(#node)}</style><script>alert(1)</script><foreignObject>bad</foreignObject><animate attributeName="href" values="#node;https://evil.example/x"></animate><set attributeName="xlink:href" to="https://evil.example/x"></set><g id="node" onclick="bad()" style="fill:url(https://evil.example/a)"><a href="https://evil.example"><path fill="url(#node)"></path></a></g></svg>`
      })
    };

    const results = await hydrateMermaid(container, { renderer });

    expect(results).toEqual([{ hash: `sha256:${digest}`, status: "rendered" }]);
    expect(container.querySelector("script, foreignObject, animate, set, [onclick]")).toBeNull();
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

    expect(results).toEqual([{
      hash: `sha256:${digest}`,
      status: "error",
      message: "Mermaid could not render this diagram."
    }]);
    expect(container.querySelector("pre.fieldnotes-mermaid-error")?.textContent).toBe("graph TD; A-->B");
  });
});
