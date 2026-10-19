import { describe, expect, it } from "vitest";
import { renderDocument } from "../src/index.js";

describe("local video", () => {
  it("renders a local video referenced with image syntax as native video", async () => {
    const result = await renderDocument('![Portal walkthrough](images/portal.mp4 "Portal film")\n', {
      sourcePath: "/notes/post/index.md"
    });

    expect(result.html).toContain(
      '<video aria-label="Portal walkthrough" controls playsinline preload="metadata" src="images/portal.mp4" title="Portal film"><a href="images/portal.mp4">Portal walkthrough</a></video>'
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
