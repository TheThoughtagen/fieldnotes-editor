import { expect, test } from "vitest";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { history, undo } from "@codemirror/commands";
import { focusImages, imageInputs, resourceURL, rewritePreviewImages } from "../src/images.js";

const settle = () => new Promise(resolve => setTimeout(resolve, 20));

function editor(source: string): EditorView {
  document.body.innerHTML = '<main id="editor"></main>';
  return new EditorView({ parent: document.querySelector("#editor")!, state: EditorState.create({ doc: source, extensions: [history(), focusImages()] }) });
}

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

  const article = document.createElement("article");
  article.innerHTML = '<img alt="local" src="images/a.png"><img alt="remote" src="https://example.com/a.png"><img alt="bad" src="javascript:alert(1)">';
  rewritePreviewImages(article, { generation: 4, allowRemoteImages: false });
  const images = [...article.querySelectorAll("img")];
  expect(images[0]!.getAttribute("src")).toBe("fieldnotes-resource://4/resource?path=images%2Fa.png");
  expect(images[1]!.hasAttribute("src")).toBe(false);
  expect(images[2]!.hasAttribute("src")).toBe(false);
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
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "images-doc", revision: 0, text: "x ![Gateway](images/a.png)", selection: { anchor: 0, head: 0 }, openContext: { generation: 9, workspaceName: "notes", documentName: "post.md", assetPolicy: "document-directory", mode: null, line: null, column: null, diagnostics: [], schema: null } });
    return Promise.resolve({ kind: "ack", documentID: "images-doc", revision: 0 });
  } } } } });
  const editor = createEditor(document.querySelector("#editor")!);
  try {
    await editor.view.dom.dataset.bridgeState;
    await settle();
    expect(document.querySelector(".fn-image-widget")).not.toBeNull();
    editor.setMode("preview");
    await settle();
    expect(document.querySelector<HTMLImageElement>(".fieldnotes-preview img")?.getAttribute("src")).toBe("fieldnotes-resource://9/resource?path=images%2Fa.png");
  } finally {
    editor.destroy();
    Object.defineProperty(window, "webkit", { configurable: true, value: undefined });
  }
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
