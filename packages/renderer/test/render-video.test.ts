import { describe, expect, it } from "vitest";
import { renderDocument } from "../src/index.js";

describe("local video", () => {
  it("renders a local video referenced with image syntax as native video", async () => {
    const result = await renderDocument('![Portal walkthrough](images/portal.mp4 "Portal film")\n', {
      sourcePath: "/notes/post/index.md"
    });

    expect(result.html).toContain(
      '<video aria-label="Portal walkthrough" controls playsinline preload="metadata" src="images/portal.mp4" title="Portal film">Portal walkthrough</video>'
    );
    expect(result.html).not.toContain("<img");
    expect(result.assets).toEqual([{
      kind: "video",
      source: "images/portal.mp4",
      remote: false,
      alt: "Portal walkthrough",
      title: "Portal film",
      resolvedPath: "/notes/post/images/portal.mp4"
    }]);
    expect(result.diagnostics.filter(diagnostic => /^(video|image)\./u.test(diagnostic.code))).toEqual([]);
  });

  it("recognizes webm and reference-style links, case-insensitively", async () => {
    const result = await renderDocument("![Clip][clip]\n\n[clip]: media/Clip.WEBM\n");

    expect(result.html).toContain('<video aria-label="Clip" controls playsinline preload="metadata" src="media/Clip.WEBM">');
    expect(result.assets).toEqual([expect.objectContaining({ kind: "video", source: "media/Clip.WEBM" })]);
  });

  it("keeps remote video URLs as images so remote media stays opt-in", async () => {
    const result = await renderDocument("![Remote](https://cdn.example.com/clip.mp4)\n", { allowRemoteImages: false });

    expect(result.html).not.toContain("<video");
    expect(result.assets).toEqual([expect.objectContaining({ kind: "image", remote: true })]);
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ code: "image.remote-disabled" }));
  });

  it("does not treat scheme or protocol-relative URLs as local video", async () => {
    for (const url of ["javascript:alert(1)//x.mp4", "//cdn.example.com/x.mp4", "data:video/mp4;base64,AAAA.mp4"]) {
      const result = await renderDocument(`![Bad](${url})\n`);
      expect(result.html).not.toContain("<video");
      expect(result.assets.every(asset => asset.kind === "image")).toBe(true);
    }
  });

  it("rejects backslash, whitespace, and root-relative paths that could reach another origin", async () => {
    for (const url of ["/\\\\evil.com/x.mp4", "\\\\\\\\evil.com/x.mp4", "/assets/x.mp4", "<b c.mp4>", "<\tclip.mp4>"]) {
      const result = await renderDocument(`![Bad](${url})\n`);
      expect(result.html, url).not.toContain("<video");
      expect(result.assets.every(asset => asset.kind === "image"), url).toBe(true);
    }
  });

  it("keeps a linked video playable", async () => {
    const result = await renderDocument("[![Clip](images/clip.mp4)](https://example.com/watch)\n");

    expect(result.html).toContain('<a href="https://example.com/watch"><video aria-label="Clip" controls playsinline preload="metadata" src="images/clip.mp4">Clip</video></a>');
    expect(result.diagnostics).not.toContainEqual(expect.objectContaining({ code: "video.raw-html" }));
  });

  it("percent-encodes video paths like image paths", async () => {
    const result = await renderDocument("![Clip](images/caf\u00e9 clip.mp4)\n".replace(" ", "%20"));

    expect(result.html).toContain('src="images/caf%C3%A9%20clip.mp4"');
  });

  it("uses the first reference definition, like the HTML output", async () => {
    const result = await renderDocument("![Clip][clip]\n\n[clip]: images/still.png\n[clip]: images/clip.mp4\n");

    expect(result.html).toContain('<img alt="Clip" src="images/still.png">');
    expect(result.assets).toEqual([expect.objectContaining({ kind: "image", source: "images/still.png" })]);
  });

  it("drops query and fragment suffixes from the resolved file path", async () => {
    const result = await renderDocument("![Clip](images/clip.mp4#t=10)\n", { sourcePath: "/notes/post/index.md" });

    expect(result.html).toContain('src="images/clip.mp4#t=10"');
    expect(result.assets).toEqual([expect.objectContaining({
      source: "images/clip.mp4#t=10",
      resolvedPath: "/notes/post/images/clip.mp4"
    })]);
  });

  it("removes raw HTML video so only Markdown-declared local media plays", async () => {
    const result = await renderDocument(
      '<video src="images/raw.mp4" autoplay onplay="bad()"><source src="https://evil.example/x.mp4"></video>\n'
    );

    expect(result.html).not.toContain("<video");
    expect(result.html).not.toContain("evil.example");
    expect(result.diagnostics).toContainEqual(expect.objectContaining({ code: "video.raw-html" }));
  });

  it("keeps ordinary images unchanged", async () => {
    const result = await renderDocument("![Chart](images/chart.png)\n");

    expect(result.html).toContain('<img alt="Chart" src="images/chart.png">');
    expect(result.assets).toEqual([expect.objectContaining({ kind: "image" })]);
  });
});
