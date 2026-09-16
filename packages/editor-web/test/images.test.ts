import { expect, test } from "vitest";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { history, undo } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { focusImages, imageInputs, markdownImages, resourceURL, rewritePreviewImages } from "../src/images.js";

const settle = () => new Promise(resolve => setTimeout(resolve, 20));

function editor(source: string): EditorView {
  document.body.innerHTML = '<main id="editor"></main>';
  return new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: source, extensions: [markdown(), history(), focusImages(() => 1)] }) });
}

test("parsed image ranges handle titles, references, balanced URLs, escaped alt text, and exclude code", () => {
  const source = '![Chart](images/chart.svg "Gateway")\n![Escaped \\]](a(b).png)\n![Ref][img]\n\n[img]: assets/ref.png\n\n`![code](no.png)`\n```\n![fence](no.png)\n```';
  const state = EditorState.create({ doc: source, extensions: markdown() });
  expect(markdownImages(state)).toEqual([
    { from: 0, to: 36, alt: "Chart", path: "images/chart.svg" },
    { from: 37, to: 60, alt: "Escaped ]", path: "a(b).png" },
    { from: 61, to: 72, alt: "Ref", path: "assets/ref.png" },
  ]);
});

test("Focus image widget shows unresolved path and reveals exact source under selection", async () => {
  const source = "before ![Gateway](images/missing.png) after";
  const view = editor(source);
  expect(document.querySelector(".fn-image-widget")?.textContent).toContain("images/missing.png");

  const imageStart = source.indexOf("![");
  view.dispatch({ selection: { anchor: imageStart + 3 } });
  await settle();
  expect(document.querySelector(".fn-image-widget")).toBeNull();
  expect(view.state.doc.toString()).toBe(source);
  view.destroy();
});

test("selecting a widget maps to Markdown so delete and undo operate on source", async () => {
  const source = "A ![Gateway](images/gateway.png) B";
  const view = editor(source);
  (document.querySelector(".fn-image-widget") as HTMLElement).click();
  expect(view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to)).toBe("![Gateway](images/gateway.png)");
  view.dispatch({ changes: view.state.selection.main, userEvent: "delete" });
  expect(view.state.doc.toString()).toBe("A  B");
  expect(undo(view)).toBe(true);
  expect(view.state.doc.toString()).toBe(source);
  view.destroy();
});

test("local resource URLs are generation scoped and preview keeps safe remote policy", () => {
  expect(resourceURL("images/gateway status.png", 12)).toBe("fieldnotes-resource://12/resource?path=images%2Fgateway%20status.png");
  expect(resourceURL("../shared.png", 12)).toBe("fieldnotes-resource://12/resource?path=..%2Fshared.png");
  expect(resourceURL("file:///tmp/secret.png", 12)).toBeNull();
  expect(resourceURL("images/a.png", 0)).toBeNull();

  const article = document.createElement("article");
  article.innerHTML = '<img alt="local" src="images/a.png"><img alt="remote" src="https://example.com/a.png"><img alt="bad" src="javascript:alert(1)">';
  rewritePreviewImages(article, { generation: 4, allowRemoteImages: false });
  const images = [...article.querySelectorAll("img")];
  expect(images[0]!.getAttribute("src")).toBe("fieldnotes-resource://4/resource?path=images%2Fa.png");
  expect(images[1]!.hasAttribute("src")).toBe(false);
  expect(images[2]!.hasAttribute("src")).toBe(false);
  expect(article.textContent).toContain("remote — https://example.com/a.png");
  expect(article.textContent).toContain("bad — javascript:alert(1)");
});

test("Preview resource failure produces an alt-and-path placeholder plus diagnostic", () => {
  const article = document.createElement("article"); article.innerHTML = '<img alt="Missing chart" src="images/missing.png">';
  const diagnostics: string[] = [];
  rewritePreviewImages(article, { generation: 3, allowRemoteImages: false }, message => diagnostics.push(message));
  article.querySelector("img")!.dispatchEvent(new Event("error"));
  expect(article.querySelector(".fn-image-error")?.textContent).toBe("Missing chart — images/missing.png");
  expect(diagnostics).toEqual(["Image unavailable: images/missing.png"]);
});

test("blocked Focus source enters error state immediately", () => {
  const view = editor("x ![Unsafe](file:///tmp/no.png)");
  expect(document.querySelector(".fn-image-widget")?.classList.contains("fn-image-error")).toBe(true);
  expect(document.querySelector(".fn-image-widget")?.textContent).toContain("file:///tmp/no.png");
  view.destroy();
});

test("loading and failed widgets remain bounded and preserve alt plus path", async () => {
  const view = editor("x ![Gateway status](images/gateway.png)");
  const widget = document.querySelector<HTMLElement>(".fn-image-widget")!;
  expect(widget.classList.contains("fn-image-loading")).toBe(true);
  expect(widget.getAttribute("aria-label")).toContain("Gateway status");
  widget.querySelector("img")!.dispatchEvent(new Event("error"));
  await settle();
  expect(widget.classList.contains("fn-image-error")).toBe(true);
  expect(widget.textContent).toContain("Gateway status");
  expect(widget.textContent).toContain("images/gateway.png");
  view.destroy();
});

test("editor wires Focus widgets and relative Preview resources to current context generation", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const { createEditor } = await import("../src/editor.js");
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "images-doc", revision: 0, text: "x ![Gateway](images/a.png)", selection: { anchor: 0, head: 0 }, openContext: { generation: 9, workspaceName: "notes", documentName: "post.md", assetPolicy: "document-directory", allowRemoteImages: false, mode: null, line: null, column: null, diagnostics: [], schema: null } });
    return Promise.resolve({ kind: "ack", documentID: "images-doc", revision: 0 });
  } } } } });
  const editor = createEditor(document.querySelector("#editor")!);
  try {
    await editor.view.dom.dataset.bridgeState;
    await settle();
    expect(document.querySelector(".fn-image-widget")).not.toBeNull();
    expect(document.querySelector<HTMLImageElement>(".fn-image-widget img")?.getAttribute("src")).toBe("fieldnotes-resource://9/resource?path=images%2Fa.png");
    expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "images-doc", revision: 0, text: "x ![Gateway](images/a.png)", selection: { anchor: 0, head: 0 }, openContext: { generation: 10, workspaceName: "moved", documentName: "post.md", assetPolicy: "document-directory", allowRemoteImages: false, mode: null, line: null, column: null, diagnostics: [], schema: null } })).toBe(true);
    await settle();
    expect(document.querySelector<HTMLImageElement>(".fn-image-widget img")?.getAttribute("src")).toBe("fieldnotes-resource://10/resource?path=images%2Fa.png");
    editor.setMode("preview");
    await settle();
    expect(document.querySelector<HTMLImageElement>(".fieldnotes-preview img")?.getAttribute("src")).toBe("fieldnotes-resource://10/resource?path=images%2Fa.png");
  } finally {
    editor.destroy();
    Object.defineProperty(window, "webkit", { configurable: true, value: undefined });
  }
});

test("production native context toggles HTTPS image policy in Focus", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const source = "x ![Remote](https://example.com/a.png)";
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "remote-doc", revision: 0, text: source, selection: { anchor: 0, head: 0 }, openContext: { generation: 1, workspaceName: "notes", documentName: "post.md", assetPolicy: "workspace", allowRemoteImages: false, mode: null, line: null, column: null, diagnostics: [], schema: null } });
    return Promise.resolve({ kind: "ack", documentID: "remote-doc", revision: 0 });
  } } } } });
  const { createEditor } = await import("../src/editor.js"); const editor = createEditor(document.querySelector("#editor")!);
  try {
    await settle(); expect(document.querySelector(".fn-image-widget")?.classList.contains("fn-image-error")).toBe(true);
    expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "remote-doc", revision: 0, text: source, selection: { anchor: 0, head: 0 }, openContext: { generation: 2, workspaceName: "notes", documentName: "post.md", assetPolicy: "workspace", allowRemoteImages: true, mode: null, line: null, column: null, diagnostics: [], schema: null } })).toBe(true);
    await settle(); expect(document.querySelector<HTMLImageElement>(".fn-image-widget img")?.getAttribute("src")).toBe("https://example.com/a.png");
  } finally { editor.destroy(); Object.defineProperty(window, "webkit", { configurable: true, value: undefined }); }
});

test("pasting an image prompts for alt text, imports bytes, and inserts one undoable source edit", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const requests: unknown[] = [];
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: "start ", extensions: [history(), imageInputs(async request => { requests.push(request); return { path: "images/gateway.png", altText: request.altText }; })] }) });
  const prompt = window.prompt;
  window.prompt = () => "Gateway status";
  try {
    const transfer = new DataTransfer();
    transfer.items.add(new File(["pixels"], "Gateway.PNG", { type: "image/png" }));
    view.contentDOM.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
    await expect.poll(() => view.state.doc.toString()).toBe("![Gateway status](images/gateway.png)start ");
    expect(requests).toEqual([{ filename: "Gateway.PNG", mimeType: "image/png", dataBase64: "cGl4ZWxz", altText: "Gateway status", linkInPlace: false }]);
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe("start ");
  } finally {
    window.prompt = prompt;
    view.destroy();
  }
});

test("option-drop requests explicit link in place using only a native file URL", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const requests: unknown[] = [];
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ extensions: imageInputs(async request => { requests.push(request); return undefined; }) }) });
  const prompt = window.prompt;
  window.prompt = () => "Diagram";
  try {
    const transfer = new DataTransfer();
    transfer.items.add(new File(["pixels"], "diagram.png", { type: "image/png" }));
    transfer.setData("text/uri-list", "file:///Users/example/diagram.png");
    view.contentDOM.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer, altKey: true }));
    await expect.poll(() => requests.length).toBe(1);
    expect(requests[0]).toEqual({ filename: "diagram.png", mimeType: "image/png", sourceURL: "file:///Users/example/diagram.png", altText: "Diagram", linkInPlace: true });
  } finally {
    window.prompt = prompt;
    view.destroy();
  }
});

test("deferred paste maps its original insertion point and ignores later selection movement", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  let finish!: (value: { path: string; altText: string }) => void;
  const response = new Promise<{ path: string; altText: string }>(resolve => { finish = resolve; });
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: "abcd", selection: { anchor: 2 }, extensions: imageInputs(() => response) }) });
  const prompt = window.prompt; window.prompt = () => "Image";
  try {
    const transfer = new DataTransfer(); transfer.items.add(new File(["p"], "a.png", { type: "image/png" }));
    view.contentDOM.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
    await settle();
    view.dispatch({ changes: { from: 0, insert: "X" }, selection: { anchor: 5 } });
    finish({ path: "images/a.png", altText: "Image" }); await settle();
    expect(view.state.doc.toString()).toBe("Xab![Image](images/a.png)cd");
  } finally { window.prompt = prompt; view.destroy(); }
});

test("editing the selected source while import is pending cancels insertion", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  let finish!: (value: { path: string; altText: string }) => void;
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: "replace me", selection: { anchor: 0, head: 7 }, extensions: imageInputs(() => new Promise(resolve => { finish = resolve; })) }) });
  const prompt = window.prompt; window.prompt = () => "Image";
  try {
    const transfer = new DataTransfer(); transfer.items.add(new File(["p"], "a.png", { type: "image/png" }));
    view.contentDOM.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer })); await settle();
    view.dispatch({ changes: { from: 1, to: 2, insert: "X" } });
    finish({ path: "images/a.png", altText: "Image" }); await settle();
    expect(view.state.doc.toString()).toBe("rXplace me");
  } finally { window.prompt = prompt; view.destroy(); }
});

test("oversized files are rejected before allocation and failed reads are visible", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const diagnostics: string[] = []; let reads = 0, imports = 0;
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ extensions: imageInputs(async () => { imports += 1; return undefined; }, message => diagnostics.push(message)) }) });
  const prompt = window.prompt; window.prompt = () => "Image";
  try {
    const large = new File(["x"], "large.png", { type: "image/png" });
    Object.defineProperty(large, "size", { value: 20_000_001 });
    large.arrayBuffer = async () => { reads += 1; return new ArrayBuffer(0); };
    const transfer = new DataTransfer(); transfer.items.add(large);
    view.contentDOM.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer })); await settle();
    expect({ reads, imports }).toEqual({ reads: 0, imports: 0 });
    expect(diagnostics).toEqual(["Image is too large: large.png"]);

    const broken = new File(["x"], "broken.png", { type: "image/png" }); broken.arrayBuffer = async () => { throw new Error("read denied"); };
    const brokenTransfer = new DataTransfer(); brokenTransfer.items.add(broken);
    view.contentDOM.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: brokenTransfer })); await settle();
    expect(diagnostics.at(-1)).toBe("Image import failed: read denied");
    expect(view.state.doc.length).toBe(0);
  } finally { window.prompt = prompt; view.destroy(); }
});

test("drop uses document coordinates instead of replacing the old selection", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const source = "paragraph A\nparagraph B";
  const view = new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: source, selection: { anchor: 0, head: 9 }, extensions: imageInputs(async request => ({ path: "images/a.png", altText: request.altText })) }) });
  const original = view.posAtCoords.bind(view); view.posAtCoords = () => source.indexOf("paragraph B");
  const prompt = window.prompt; window.prompt = () => "Dropped";
  try {
    const transfer = new DataTransfer(); transfer.items.add(new File(["p"], "a.png", { type: "image/png" }));
    view.contentDOM.dispatchEvent(new DragEvent("drop", { bubbles: true, cancelable: true, dataTransfer: transfer, clientX: 10, clientY: 10 }));
    await expect.poll(() => view.state.doc.toString()).toContain("![Dropped](images/a.png)paragraph B");
    expect(view.state.doc.toString().startsWith("paragraph A")).toBe(true);
  } finally { view.posAtCoords = original; window.prompt = prompt; view.destroy(); }
});
