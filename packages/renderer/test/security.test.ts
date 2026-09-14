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
});
