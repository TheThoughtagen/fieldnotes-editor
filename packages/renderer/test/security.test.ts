import { describe, expect, it } from "vitest";
import { normalizeHtml, renderDocument } from "../src/index.js";

describe("hostile document input", () => {
  it.each([
    ["<script>alert(1)</script>", "script"],
    ["<style>body{display:none}</style>", "style"],
    ["<img src=x onerror=alert(1)>", "onerror"],
    ["[x](javascript:alert(1))", "javascript:"],
    ["[x](data:text/html,alert(1))", "data:text"],
    ["<svg><script>alert(1)</script><circle></circle></svg>", "svg"],
    ["<iframe src='https://evil.example/x'></iframe>", "iframe"]
  ])("removes %s", async (source, forbidden) => {
    const result = await renderDocument(source);

    expect(result.html.toLocaleLowerCase()).not.toContain(forbidden);
  });

  it("protects raw id/name attributes while retaining trusted Markdown heading IDs", async () => {
    const result = await renderDocument(`<div id="location" name="cookie">raw</div>

<h2 id="spoofed-heading">Raw heading</h2>

## Trusted heading
`);

    expect(result.html).not.toContain('id="location"');
    expect(result.html).not.toContain('name="cookie"');
    expect(result.html).not.toContain('id="spoofed-heading"');
    expect(result.html).toContain('id="user-content-location"');
    expect(result.html).toContain('<h2 id="trusted-heading">Trusted heading</h2>');
  });

  it("retains exact IDs only for validated explicit heading anchors", async () => {
    const result = await renderDocument(`<a id="standalone"></a>

<a id="stable-heading"></a>

## Visible heading
`);

    expect(result.html).not.toContain('id="standalone"');
    expect(result.html).toContain('<a id="stable-heading"></a>');
    expect(result.html).toContain('<h2 id="stable-heading">Visible heading</h2>');
  });

  it("does not trust raw data-highlight-lines provenance", async () => {
    const result = await renderDocument('<pre><code data-highlight-lines="1">raw code</code></pre>');

    expect(result.html).not.toContain("data-highlight-lines");
    expect(result.html).not.toContain("data-highlighted-line");
    expect(result.html).not.toContain("code-line");
  });

  it("removes source and srcset from raw picture markup", async () => {
    const result = await renderDocument('<picture><source srcset="https://evil.example/a.png 2x"><img src="safe.png" alt="Safe"></picture>');

    expect(result.html).not.toContain("<source");
    expect(result.html).not.toContain("srcset");
    expect(result.html).toContain('<img alt="Safe" src="safe.png">');
  });
});

describe("trusted footnote references", () => {
  it("keeps every fragment and aria-describedby reference connected to an exact ID", async () => {
    const result = await renderDocument(`First[^shared], repeated[^shared], and second[^other].

[^shared]: Shared evidence.
[^other]: Other evidence.
`);
    const ids = new Set([...result.html.matchAll(/\sid="([^"]+)"/gu)].map(match => match[1]));
    const fragments = [...result.html.matchAll(/\shref="#([^"]+)"/gu)].map(match => match[1]);
    const describedBy = [...result.html.matchAll(/\saria-describedby="([^"]+)"/gu)]
      .flatMap(match => match[1].split(/\s+/u));

    expect(fragments.length).toBeGreaterThanOrEqual(5);
    expect(describedBy.length).toBe(3);
    for (const target of [...fragments, ...describedBy]) {
      expect(ids, `missing exact target for ${target}`).toContain(target);
    }
    expect(result.html).not.toContain("user-content-user-content-");
  });

  it("restores only generated footer nodes when definitions contain nested and spoofed markup", async () => {
    const result = await renderDocument(`First[^one] and second[^two].

[^one]: First paragraph.

    - nested item

    ## heading inside definition

    <a data-footnote-backref href="#user-content-fnref-two">raw spoof</a>

[^two]: Second paragraph.
`);
    const ids = [...result.html.matchAll(/\sid="([^"]+)"/gu)].map(match => match[1]);
    const idSet = new Set(ids);
    const fragments = [...result.html.matchAll(/\shref="#([^"]+)"/gu)].map(match => match[1]);
    const describedBy = [...result.html.matchAll(/\saria-describedby="([^"]+)"/gu)]
      .flatMap(match => match[1].split(/\s+/u));

    expect(ids).toHaveLength(idSet.size);
    for (const target of [...fragments, ...describedBy]) {
      expect(idSet, `missing exact target for ${target}`).toContain(target);
    }
    expect(result.html).toContain('data-footnote-backref="" href="#user-content-fnref-two">raw spoof</a>');
    expect(result.html).toContain('<ul>\n<li>nested item</li>');
    expect(result.html).toContain('>heading inside definition</h2>');
  });

  it("does not restore ordinary definition headings through footer structural paths", async () => {
    const result = await renderDocument(`Reference[^one] and another[^two].

[^one]: Before expansion.

    <script>removed before the nested heading</script>

    ## nested trusted heading

    <h2 id="raw-one">expanded one</h2><h2 id="raw-two">expanded two</h2><h2 id="raw-three">expanded three</h2><script>removed after the nested heading</script>

[^two]: Other definition.
`);
    const ids = [...result.html.matchAll(/\sid="([^"]+)"/gu)].map(match => match[1]);
    const idSet = new Set(ids);
    const fragments = [...result.html.matchAll(/\shref="#([^"]+)"/gu)].map(match => match[1]);
    const describedBy = [...result.html.matchAll(/\saria-describedby="([^"]+)"/gu)]
      .flatMap(match => match[1].split(/\s+/u));

    expect(result.html).toContain(">expanded one</h2><h2");
    expect(result.html).toContain(">expanded two</h2>");
    expect(result.html).toContain(">expanded three</h2>");
    expect(result.html).not.toContain("<script");
    expect(result.html).toContain('<h2 id="nested-trusted-heading">nested trusted heading</h2>');
    expect(ids).toHaveLength(idSet.size);
    for (const target of [...fragments, ...describedBy]) {
      expect(idSet, `missing exact target for ${target}`).toContain(target);
    }
  });
});

describe("iframe allowlist", () => {
  it.each([
    "https://www.youtube-nocookie.com/embed/abc-123",
    "https://player.vimeo.com/video/123456"
  ])("retains the allowed embed %s with only fixed attributes", async src => {
    const result = await renderDocument(
      `<iframe src="${src}" title="A video" width="560" height="315" allowfullscreen id="remove" class="remove" style="color:red" onclick="bad()"></iframe>`
    );

    expect(result.html).toBe(
      `<iframe allowfullscreen height="315" sandbox="allow-scripts allow-same-origin allow-presentation" src="${src}" title="A video" width="560"></iframe>`
    );
    expect(result.diagnostics).not.toContainEqual(expect.objectContaining({ code: "iframe.invalid-source" }));
  });

  it.each([
    "http://www.youtube-nocookie.com/embed/abc",
    "https://user:pass@www.youtube-nocookie.com/embed/abc",
    "https://www.youtube-nocookie.com:444/embed/abc",
    "https://www.youtube-nocookie.com/embed/",
    "https://www.youtube-nocookie.com/embed/abc/nested",
    "https://www.youtube-nocookie.com.evil.example/embed/abc",
    "https://player.vimeo.com/video/",
    "https://player.vimeo.com/video/not-a-number",
    "https://player.vimeo.com/video/123/nested",
    "https://player.vimeo.com.evil.example/video/123"
  ])("removes and diagnoses invalid embed %s", async src => {
    const result = await renderDocument(`<iframe src="${src}"></iframe>`);

    expect(result.html).not.toContain("<iframe");
    expect(result.diagnostics).toContainEqual({
      code: "iframe.invalid-source",
      message: `Iframe source is not allowed: ${src}`,
      severity: "warning"
    });
  });

  it("escapes dangerous query text without changing an allowed embed path", async () => {
    const src = "https://www.youtube-nocookie.com/embed/abc?label=%3Cscript%3E&autoplay=0";
    const result = await renderDocument(`<iframe src="${src.replace("&", "&amp;")}"></iframe>`);

    expect(result.html).toContain("/embed/abc?label=%3Cscript%3E&#x26;autoplay=0");
    expect(result.html).not.toContain("<script>");
  });

  it.each([
    "https://www.youtube-nocookie.com:443/embed/abc",
    "https://www.youtube-nocookie.com/embed/abc#start",
    "https://player.vimeo.com:443/video/123#chapter"
  ])("accepts contract-safe port and fragment form %s", async src => {
    const result = await renderDocument(`<iframe src="${src}"></iframe>`);

    expect(result.html).toContain(`<iframe sandbox="allow-scripts allow-same-origin allow-presentation" src="${src}"></iframe>`);
  });

  it("rejects a protocol-relative allowlisted host", async () => {
    const src = "//www.youtube-nocookie.com/embed/abc";
    const result = await renderDocument(`<iframe src="${src}"></iframe>`);

    expect(result.html).not.toContain("<iframe");
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ code: "iframe.invalid-source" }));
  });

  it.each([
    ["-1", "width"],
    ["0", "height"],
    ["12.5", "width"],
    ["wide", "width"],
    ["20px", "height"]
  ])("drops non-integer iframe %s=%s", async (value, attribute) => {
    const result = await renderDocument(
      `<iframe src="https://player.vimeo.com/video/123" ${attribute}="${value}"></iframe>`
    );

    expect(result.html).not.toContain(`${attribute}=`);
    expect(result.html).toContain('sandbox="allow-scripts allow-same-origin allow-presentation"');
  });
});

describe("deterministic normalization", () => {
  it("sorts attributes, normalizes line endings, and uses one void-element form", () => {
    expect(normalizeHtml('<p title="z" id="a">one\r\ntwo<br/><img title="t" src="x" alt="a" /></p>')).toBe(
      '<p id="a" title="z">one\ntwo<br><img alt="a" src="x" title="t"></p>'
    );
  });

  it("is idempotent", () => {
    const once = normalizeHtml('<img width="10" alt="A" src="image.png">');
    expect(normalizeHtml(once)).toBe(once);
  });

  it("sorts by final HTML attribute names rather than HAST property keys", () => {
    expect(normalizeHtml('<label frameborder="1" form="owner" for="field" data-z="z" class="label" aria-label="Field"></label>')).toBe(
      '<label aria-label="Field" class="label" data-z="z" for="field" form="owner" frameborder="1"></label>'
    );
  });
});
