import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { conformanceCases } from "@cruciblesoftware/fieldnotes-renderer/conformance";
import { normalizeRenderedDom } from "@cruciblesoftware/fieldnotes-renderer/browser";
import type { RenderedDocument } from "@cruciblesoftware/fieldnotes-renderer";

const settle = () => new Promise(resolve => setTimeout(resolve, 40));

test("one EditorView survives Focus Source and Preview shortcuts", async () => {
  document.body.innerHTML = '<main id="editor" aria-label="Markdown editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: "# Title\n\nHello **world**" });
  const view = editor.view;

  expect(root.getAttribute("role")).toBeNull();
  expect(editor.mode).toBe("focus");
  await userEvent.keyboard("{Meta>}2{/Meta}");
  expect(editor.mode).toBe("source");
  expect(editor.view).toBe(view);
  await userEvent.keyboard("{Meta>}3{/Meta}");
  await settle();
  expect(editor.mode).toBe("preview");
  expect(editor.view).toBe(view);
  expect(root.querySelector("article")?.textContent).toContain("Hello world");
  expect(root.querySelector("article")?.getAttribute("contenteditable")).toBe("false");
  await userEvent.keyboard("{Meta>}1{/Meta}");
  expect(editor.mode).toBe("focus");
  expect(editor.view.state.doc.toString()).toContain("Hello **world**");
  editor.destroy();
});

test("preview sanitizes unsafe Markdown and a stale render cannot win", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: '<script>window.pwned=1</script>\n\n[local](#safe)' });
  editor.setMode("preview");
  await settle();
  expect(root.querySelector("script")).toBeNull();
  expect(root.querySelector<HTMLAnchorElement>('article a')?.getAttribute("href")).toBe("#safe");
  expect((window as Window & { pwned?: number }).pwned).toBeUndefined();
  editor.destroy();
  expect(root.childElementCount).toBe(0);
});

test.each(conformanceCases)("preview matches shared hydrated DOM for $name", async fixture => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: fixture.source });
  editor.setMode("preview");
  const preview = document.querySelector<HTMLElement>(".fieldnotes-preview")!;
  const expectedWrapper = document.createElement("main");
  expectedWrapper.innerHTML = fixture.expected.hydratedDom;
  expectedWrapper.querySelectorAll<HTMLImageElement>("img[src]").forEach(image => image.removeAttribute("src"));
  expectedWrapper.querySelectorAll("iframe").forEach(frame => frame.remove());
  await expect.poll(() => ({ children: preview.childElementCount, pending: preview.querySelectorAll("pre.fieldnotes-mermaid").length }), { timeout: 10_000 })
    .toEqual({ children: expectedWrapper.firstElementChild?.childElementCount ?? 0, pending: 0 });
  const wrapper = document.createElement("main");
  wrapper.id = "fixture";
  wrapper.innerHTML = preview.innerHTML;
  expect(normalizeRenderedDom(wrapper)).toBe(normalizeRenderedDom(expectedWrapper.firstElementChild!));
  expect(preview.querySelector("script, [onclick], [onerror]")).toBeNull();
  editor.destroy();
});

test("newer preview wins when the older render resolves last", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const pending: Array<(value: RenderedDocument) => void> = [];
  const render = () => new Promise<RenderedDocument>(resolve => pending.push(resolve));
  const result = (html: string): RenderedDocument => ({ html, normalizedHtml: html, toc: [], frontmatter: {}, diagnostics: [], assets: [], plainText: html, wordCount: 1, readingMinutes: 1 });
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "A", render });
  editor.setMode("preview");
  editor.setMode("source");
  editor.view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
  editor.setMode("preview");
  pending[1]!(result("<p>new B</p>"));
  await settle();
  pending[0]!(result("<p>stale A</p>"));
  await settle();
  expect(document.querySelector(".fieldnotes-preview")?.textContent).toBe("new B");
  editor.destroy();
});

test("Vim is enabled by default and its adapter is stable across modes", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const { getCM } = await import("@replit/codemirror-vim");
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "one two" });
  const adapter = getCM(editor.view);
  expect(adapter).not.toBeNull();
  editor.setMode("source");
  editor.setMode("preview");
  editor.setMode("focus");
  expect(getCM(editor.view)).toBe(adapter);
  expect(editor.vimEnabled).toBe(true);
  editor.setVimEnabled(false);
  expect(editor.vimEnabled).toBe(false);
  editor.destroy();
});

test("Vim status listener follows the public adapter after re-enabling", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const modes: string[] = [];
  const editor = createEditor(document.querySelector("#editor")!, {
    initialDocument: "one two",
    onStatus: status => modes.push(status.vimMode),
  });

  editor.setVimEnabled(false);
  editor.setVimEnabled(true);
  editor.view.focus();
  await userEvent.keyboard("i");
  await settle();

  expect(modes.at(-1)).toBe("insert");
  editor.destroy();
});

test("status reports mode, cursor and document metrics", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const statuses: unknown[] = [];
  const editor = createEditor(document.querySelector("#editor")!, {
    initialDocument: "one two\nthree",
    onStatus: status => statuses.push(status),
  });
  editor.view.dispatch({ selection: { anchor: 8 } });
  await settle();
  expect(statuses.at(-1)).toMatchObject({ presentationMode: "focus", line: 2, column: 1, wordCount: 3 });
  editor.destroy();
});

test("Focus recognizes exact CRLF frontmatter and reveals enclosing Markdown syntax", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const source = "---\r\ntitle: x\r\n---\r\n\r\n**bold**";
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: source });
  expect(document.querySelectorAll(".fn-frontmatter").length).toBeGreaterThan(0);
  editor.view.dispatch({ selection: { anchor: source.indexOf("bold") + 1 } });
  await settle();
  expect([...document.querySelectorAll<HTMLElement>(".fn-syntax-active")].some(element => element.textContent?.includes("*"))).toBe(true);
  editor.destroy();

  const invalid = createEditor(document.querySelector("#editor")!, { initialDocument: "---oops\ntitle: x\n---" });
  expect(document.querySelector(".fn-frontmatter")).toBeNull();
  invalid.destroy();
});
