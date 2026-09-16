import { expect, test } from "vitest";
import { conformanceCases } from "@cruciblesoftware/fieldnotes-renderer/conformance";
import { renderDocument } from "@cruciblesoftware/fieldnotes-renderer";
import { normalizeRenderedDom } from "@cruciblesoftware/fieldnotes-renderer/browser";
import { createEditor } from "../src/editor.js";
import { rewritePreviewImages } from "../src/images.js";

for (const fixture of conformanceCases) {
  test(`editor consumes literal HTML/TOC and final SVG: ${fixture.name}`, async () => {
    const root = document.createElement("main"); document.body.append(root);
    let observed = false;
    const editor = createEditor(root, {
      initialDocument: fixture.source, allowRemoteImages: fixture.name === "unsafe-html",
      render: async source => {
        const result = await renderDocument(source, fixture.options);
        expect(result.normalizedHtml).toBe(fixture.expected.renderer.normalizedHtml);
        expect(result.toc).toEqual(fixture.expected.renderer.toc);
        observed = true; return result;
      },
    });
    try {
      const expected = document.createElement("div"); expected.innerHTML = fixture.expected.hydratedDom;
      const expectedMain = expected.firstElementChild as HTMLElement;
      rewritePreviewImages(expectedMain, { generation: 0, allowRemoteImages: fixture.name === "unsafe-html" });
      editor.setMode("preview");
      const actual = document.createElement("main"); actual.id = "fixture";
      await expect.poll(() => {
        actual.innerHTML = root.querySelector("article")!.innerHTML;
        return normalizeRenderedDom(actual);
      }, { timeout: 5000 }).toBe(normalizeRenderedDom(expectedMain));
      expect(observed).toBe(true);
      expect([...actual.querySelectorAll("svg")].map(svg => normalizeRenderedDom(svg)))
        .toEqual([...expectedMain.querySelectorAll("svg")].map(svg => normalizeRenderedDom(svg)));
    } finally { editor.destroy(); root.remove(); }
  });
}

test("native remote-media preference removes allowed frames and never accepts undeclared hosts", async () => {
  const root = document.createElement("main"); document.body.append(root);
  const editor = createEditor(root, { initialDocument: '<iframe src="https://www.youtube-nocookie.com/embed/abc"></iframe>\n<iframe src="https://player.vimeo.com/video/123"></iframe>\n<iframe src="https://evil.example/embed/abc"></iframe>' });
  try {
    const context = (generation: number, allowRemoteImages: boolean) => ({ kind: "snapshot", documentID: "media", revision: 0, text: editor.view.state.doc.toString(), selection: { anchor: 0, head: 0 }, openContext: { generation, workspaceName: "notes", documentName: "note.md", assetPolicy: "workspace", allowRemoteImages, mode: "preview", line: null, column: null, diagnostics: [], schema: null } });
    window.fieldnotes.applyNativeSnapshot(context(1, true));
    await expect.poll(() => root.querySelectorAll("iframe").length).toBe(2);
    expect([...root.querySelectorAll("iframe")].every(frame => frame.getAttribute("sandbox") === "allow-scripts allow-same-origin allow-presentation")).toBe(true);
    window.fieldnotes.applyNativeSnapshot(context(2, false));
    await expect.poll(() => root.querySelectorAll("iframe").length).toBe(0);
  } finally { editor.destroy(); root.remove(); }
});
