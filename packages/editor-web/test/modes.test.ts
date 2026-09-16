import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { conformanceCases } from "@cruciblesoftware/fieldnotes-renderer/conformance";
import { normalizeRenderedDom } from "@cruciblesoftware/fieldnotes-renderer/browser";
import type { RenderedDocument } from "@cruciblesoftware/fieldnotes-renderer";
import { rewritePreviewImages } from "../src/images.js";

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
  rewritePreviewImages(expectedWrapper, { generation: 0, allowRemoteImages: false });
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

test("active Preview rerenders a newer native snapshot and rejects its stale render", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const pending: Array<{ source: string; resolve: (value: RenderedDocument) => void }> = [];
  const render = (source: string) => new Promise<RenderedDocument>(resolve => pending.push({ source, resolve }));
  const result = (html: string): RenderedDocument => ({ html, normalizedHtml: html, toc: [], frontmatter: {}, diagnostics: [], assets: [], plainText: html, wordCount: 1, readingMinutes: 1 });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "preview-doc", revision: 0, text: "A", selection: { anchor: 0, head: 0 } });
    return Promise.resolve({ kind: "ack", documentID: "preview-doc", revision: 1 });
  } } } } });
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "A", render });
  try {
    await expect.poll(() => editor.view.dom.dataset.bridgeState).toBe("ready");
    editor.setMode("preview");
    await expect.poll(() => pending.map(item => item.source)).toEqual(["A"]);

    expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "preview-doc", revision: 1, text: "B", selection: { anchor: 0, head: 0 } })).toBe(true);
    await expect.poll(() => pending.map(item => item.source)).toEqual(["A", "B"]);
    pending[1]!.resolve(result("<p>new B</p>"));
    await settle();
    pending[0]!.resolve(result("<p>stale A</p>"));
    await settle();

    expect(document.querySelector(".fieldnotes-preview")?.textContent).toBe("new B");
  } finally {
    editor.destroy();
    Object.defineProperty(window, "webkit", { configurable: true, value: undefined });
  }
});

test("malformed local fragment is a safe no-op", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const result: RenderedDocument = { html: '<p><a href="#%GG">broken fragment</a></p>', normalizedHtml: "", toc: [], frontmatter: {}, diagnostics: [], assets: [], plainText: "broken fragment", wordCount: 2, readingMinutes: 1 };
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "ignored", render: async () => result });
  let reportedError: ErrorEvent | undefined;
  const captureError = (event: ErrorEvent) => { reportedError = event; event.preventDefault(); };
  window.addEventListener("error", captureError);
  try {
    editor.setMode("preview");
    await expect.poll(() => document.querySelector<HTMLAnchorElement>('.fieldnotes-preview a')?.href).toContain("#%GG");
    document.querySelector<HTMLAnchorElement>('.fieldnotes-preview a')!.click();
    await settle();
    expect(reportedError).toBeUndefined();
    expect(document.querySelector(".fieldnotes-preview")?.textContent).toBe("broken fragment");
  } finally {
    window.removeEventListener("error", captureError);
    editor.destroy();
  }
});

test.each(["resolve", "reject"] as const)("destroy synchronously removes a pending hydration stage before late $0", async outcome => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const result: RenderedDocument = { html: "<p>pending</p>", normalizedHtml: "", toc: [], frontmatter: {}, diagnostics: [], assets: [], plainText: "pending", wordCount: 1, readingMinutes: 1 };
  let finishHydration!: () => void;
  const hydrate = () => new Promise<[]>((resolve, reject) => {
    finishHydration = () => outcome === "resolve" ? resolve([]) : reject(new Error("late hydration"));
  });
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "pending", render: async () => result, hydrate });
  let reportedError: ErrorEvent | undefined;
  const captureError = (event: ErrorEvent) => { reportedError = event; event.preventDefault(); };
  window.addEventListener("error", captureError);
  try {
    editor.setMode("preview");
    await expect.poll(() => document.querySelectorAll(".fieldnotes-render-stage").length).toBe(1);
    editor.destroy();
    const stagesImmediatelyAfterDestroy = document.querySelectorAll(".fieldnotes-render-stage").length;
    finishHydration();
    await settle();

    expect(stagesImmediatelyAfterDestroy).toBe(0);
    expect(document.querySelectorAll(".fieldnotes-render-stage")).toHaveLength(0);
    expect(document.querySelector("#editor")?.childElementCount).toBe(0);
    expect(reportedError).toBeUndefined();
  } finally {
    window.removeEventListener("error", captureError);
    finishHydration?.();
    editor.destroy();
  }
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
  editor.view.dispatch({ changes: { from: editor.view.state.doc.length, insert: "\nfour" } });
  await settle();
  expect(statuses.at(-1)).toMatchObject({ wordCount: 4 });
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

test("Focus reuses its frontmatter extent on selection-only updates", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  const source = `---\ntitle: large\n---\n${"content line\n".repeat(20_000)}`;
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: source });
  const documentText = editor.view.state.doc;
  const prototype = Object.getPrototypeOf(documentText) as { toString(): string };
  const originalToString = prototype.toString;
  let fullMaterializations = 0;
  prototype.toString = function(this: typeof documentText): string {
    if (this === documentText) fullMaterializations += 1;
    return originalToString.call(this);
  };
  try {
    editor.view.dispatch({ selection: { anchor: source.length - 2 } });
    await settle();
    expect(editor.view.state.doc).toBe(documentText);
    expect(fullMaterializations).toBe(0);
  } finally {
    prototype.toString = originalToString;
    editor.destroy();
  }
});

test("Focus recognizes BOM and whitespace frontmatter delimiters including empty metadata", async () => {
  const { createEditor } = await import("../src/editor.js");
  for (const source of ["\uFEFF--- \t\ntitle: x\n---\t \n# Body", "---\n---\n# Body"]) {
    const parent = document.createElement("main"); document.body.append(parent);
    const editor = createEditor(parent, { initialDocument: source });
    try { expect(parent.querySelector(".fn-frontmatter")).not.toBeNull(); }
    finally { editor.destroy(); parent.remove(); }
  }
});
