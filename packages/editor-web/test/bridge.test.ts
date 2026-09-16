import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { expect, test, vi } from "vitest";
import { userEvent } from "vitest/browser";
import { createNativeBridge, type NativeReply } from "../src/bridge.js";

function editor(text = "one") {
  const parent = document.createElement("div");
  document.body.replaceChildren(parent);
  return new EditorView({ state: EditorState.create({ doc: text }), parent });
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

test("image replies are rejected after a newer context and allow only the first-save transition", async () => {
  const image = deferred<unknown>();
  const context = { generation: 1, workspaceName: "notes", documentName: "note.md", assetPolicy: "workspace" as const, allowRemoteImages: false, mode: null, line: null, column: null, diagnostics: [], schema: null };
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "", selection: { anchor: 0, head: 0 }, openContext: context });
    if (message.kind === "imageImport") return image.promise;
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: 0 });
  } } } } });
  const view = editor(""), bridge = createNativeBridge(view); await bridge.ready;
  const pending = bridge.importImage({ filename: "a.png", mimeType: "image/png", dataBase64: "AA==", altText: "A", linkInPlace: false });
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 0, text: "", selection: { anchor: 0, head: 0 }, openContext: { ...context, generation: 2 } })).toBe(true);
  image.resolve({ kind: "imageImported", documentID: "doc", revision: 0, generation: 1, path: "images/a.png", altText: "A" });
  await expect(pending).rejects.toThrow("Stale image import response");
  bridge.destroy(); view.destroy();

  const firstSave = deferred<unknown>();
  const unsaved = { ...context, documentName: null };
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "new", revision: 0, text: "", selection: { anchor: 0, head: 0 }, openContext: unsaved });
    if (message.kind === "imageImport") return firstSave.promise;
    return Promise.resolve({ kind: "ack", documentID: "new", revision: 0 });
  } } } } });
  const newView = editor(""), newBridge = createNativeBridge(newView); await newBridge.ready;
  const saved = newBridge.importImage({ filename: "a.png", mimeType: "image/png", dataBase64: "AA==", altText: "A", linkInPlace: false });
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "new", revision: 0, text: "", selection: { anchor: 0, head: 0 }, openContext: { ...unsaved, documentName: "note.md", generation: 2 } })).toBe(true);
  firstSave.resolve({ kind: "imageImported", documentID: "new", revision: 0, generation: 2, path: "images/a.png", altText: "A" });
  await expect(saved).resolves.toEqual({ path: "images/a.png", altText: "A" });
  newBridge.destroy(); newView.destroy();
});

test("handler is absent and the exported global is narrow and frozen", () => {
  delete (window as Window & { webkit?: unknown }).webkit;
  const view = editor();
  const bridge = createNativeBridge(view);
  expect(bridge.available).toBe(false);
  expect(Object.keys(window.fieldnotes)).toEqual([
    "applyNativeSnapshot", "setMode", "cycleMode", "setVimEnabled", "toggleVim", "destroy",
  ]);
  expect(Object.isFrozen(window.fieldnotes)).toBe(true);
});

test("ready sends the exact closed envelope", async () => {
  const replies: NativeReply[] = [{ kind: "snapshot", documentID: "doc", revision: 0, text: "native", selection: { anchor: 0, head: 0 } }];
  const postMessage = vi.fn(async (_message: unknown) => replies.shift());
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  createNativeBridge(editor());
  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledOnce());
  expect(postMessage.mock.calls[0]?.[0]).toEqual({ kind: "ready", documentID: "", baseRevision: 0, revision: 0, payload: {} });
});

test("edits are ACK-ordered and in-flight changes coalesce without optimistic revision", async () => {
  let resolveFirst: ((value: NativeReply) => void) | undefined;
  const postMessage = vi.fn((message: unknown) => {
    if ((message as { kind: string }).kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "one", selection: { anchor: 0, head: 0 } });
    if (!resolveFirst) return new Promise<NativeReply>((resolve) => { resolveFirst = resolve; });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: 2 });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;

  view.dispatch({ changes: { from: 0, to: 3, insert: "two" } });
  view.dispatch({ changes: { from: 0, to: 3, insert: "three" } });
  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(2));
  expect(postMessage.mock.calls[1]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 0, revision: 1 });
  resolveFirst?.({ kind: "ack", documentID: "doc", revision: 1 });
  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(3));
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 1, revision: 2, payload: { text: "three" } });
});

test("coalesced status waits for the pending edit acknowledgement", async () => {
  const editAck = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "one", selection: { anchor: 0, head: 0 } });
    if (envelope.kind === "transaction") return editAck.promise;
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: 1 });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 3, insert: "two" } });
  bridge.postStatus({ presentationMode: "focus", vimMode: "normal", line: 1, column: 4, wordCount: 1 });
  await new Promise(resolve => setTimeout(resolve, 50));
  expect(postMessage.mock.calls.map(([message]) => (message as { kind: string }).kind)).toEqual(["ready", "transaction"]);
  editAck.resolve({ kind: "ack", documentID: "doc", revision: 1 });
  await vi.waitFor(() => expect(postMessage.mock.calls.map(([message]) => (message as { kind: string }).kind)).toEqual(["ready", "transaction", "status"]));
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ baseRevision: 1, revision: 1, payload: { column: 4 } });
});

test("native echo snapshot accepts the in-flight edit without overwriting newer queued text", async () => {
  const firstAck = deferred<NativeReply>();
  const secondAck = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    return postMessage.mock.calls.length === 2 ? firstAck.promise : secondAck.promise;
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;

  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
  view.dispatch({ changes: { from: 0, to: 1, insert: "C" } });
  expect(view.state.doc.toString()).toBe("C");
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 1, text: "B", selection: { anchor: 1, head: 1 } })).toBe(true);

  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(3));
  expect(view.state.doc.toString()).toBe("C");
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 1, revision: 2, payload: { text: "C" } });
  firstAck.resolve({ kind: "ack", documentID: "doc", revision: 1 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(view.state.doc.toString()).toBe("C");
});

test("native bridge keeps the editor read-only until the initial snapshot arrives", async () => {
  const readyReply = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    if ((message as { kind: string }).kind === "ready") return readyReply.promise;
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: 1 });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor("placeholder");
  const bridge = createNativeBridge(view);

  expect(view.contentDOM.contentEditable).toBe("false");
  view.contentDOM.focus();
  await userEvent.keyboard("lost");
  expect(view.state.doc.toString()).toBe("placeholder");

  readyReply.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "native source", selection: { anchor: 13, head: 13 } });
  await bridge.ready;
  expect(view.contentDOM.contentEditable).toBe("true");
  expect(view.state.readOnly).toBe(false);
  await userEvent.type(view.contentDOM, "x");
  expect(view.state.doc.toString()).toContain("x");
});

test("delayed ACK cannot roll back a newer authoritative snapshot", async () => {
  const delayedAck = deferred<NativeReply>();
  const currentAck = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (postMessage.mock.calls.length === 2) return delayedAck.promise;
    if (postMessage.mock.calls.length === 3) return currentAck.promise;
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: 4 });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });

  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 2, text: "native two", selection: { anchor: 10, head: 10 } })).toBe(true);
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "local three" } });
  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(3));
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 2, revision: 3, payload: { text: "local three" } });

  delayedAck.resolve({ kind: "ack", documentID: "doc", revision: 1 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(postMessage).toHaveBeenCalledTimes(3);
  expect(view.state.doc.toString()).toBe("local three");

  currentAck.resolve({ kind: "ack", documentID: "doc", revision: 3 });
  await new Promise((resolve) => setTimeout(resolve, 0));
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "local four" } });
  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(4));
  expect(postMessage.mock.calls[3]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 3, revision: 4, payload: { text: "local four" } });
});

test("equal revision snapshots reject text conflicts but apply authoritative selection without echo", async () => {
  const postMessage = vi.fn(async (_message: unknown) => ({ kind: "snapshot", documentID: "doc", revision: 2, text: "same", selection: { anchor: 0, head: 0 } }));
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  postMessage.mockClear();

  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 2, text: "conflict", selection: { anchor: 0, head: 0 } })).toBe(false);
  expect(view.state.doc.toString()).toBe("same");
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 2, text: "same", selection: { anchor: 4, head: 1 } })).toBe(true);
  expect(view.state.selection.main).toMatchObject({ anchor: 4, head: 1 });
  expect(postMessage).not.toHaveBeenCalled();
});

test("identity document changes cannot deadlock the next real edit", async () => {
  const postMessage = vi.fn(async (message: unknown) => {
    const envelope = message as { kind: string; revision: number };
    if (envelope.kind === "ready") return { kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } };
    if (envelope.kind === "selection") return { kind: "ack", documentID: "doc", revision: 0 };
    return { kind: "ack", documentID: "doc", revision: envelope.revision };
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;

  view.dispatch({ changes: { from: 0, to: 1, insert: "A" }, selection: { anchor: 0 } });
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 0, head: 0 } })).toBe(true);
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });

  await vi.waitFor(() => expect(postMessage.mock.calls.some(([message]) => (
    (message as { kind?: string; payload?: { text?: string } }).kind === "transaction"
      && (message as { payload?: { text?: string } }).payload?.text === "B"
  ))).toBe(true));
  const transactions = postMessage.mock.calls.map(([message]) => message as { kind: string; baseRevision: number; revision: number; payload?: { text?: string } }).filter((message) => message.kind === "transaction");
  expect(transactions).toEqual([{ kind: "transaction", documentID: "doc", baseRevision: 0, revision: 1, payload: expect.objectContaining({ text: "B" }) }]);
});

test("rejected transaction recovers a snapshot base and sends the latest visible edit", async () => {
  const failedEdit = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string; revision: number };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "transaction" && postMessage.mock.calls.length === 2) return failedEdit.promise;
    if (envelope.kind === "requestSnapshot") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: envelope.revision });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
  view.dispatch({ changes: { from: 0, to: 1, insert: "C" } });
  failedEdit.reject(new Error("delivery failed"));

  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(4));
  expect(view.state.doc.toString()).toBe("C");
  expect(view.dom.dataset.bridgeState).toBe("ready");
  expect(postMessage.mock.calls[2]?.[0]).toEqual({ kind: "requestSnapshot", documentID: "doc", baseRevision: 0, revision: 0, payload: {} });
  expect(postMessage.mock.calls[3]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 0, revision: 1, payload: { text: "C" } });
});

test("invalid transaction reply uses one snapshot recovery before resending", async () => {
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string; revision: number };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 4, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "transaction" && postMessage.mock.calls.length === 2) return Promise.resolve({ kind: "ack", documentID: "doc", revision: 999, extra: true });
    if (envelope.kind === "requestSnapshot") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 4, text: "A", selection: { anchor: 1, head: 1 } });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: envelope.revision });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });

  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(4));
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ kind: "requestSnapshot", baseRevision: 4, revision: 4 });
  expect(postMessage.mock.calls[3]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 4, revision: 5, payload: { text: "B" } });
  expect(view.dom.dataset.bridgeState).toBe("ready");
});

test("a failed post-recovery resend disconnects instead of looping", async () => {
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "requestSnapshot") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    return Promise.reject(new Error("delivery failed"));
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });

  await vi.waitFor(() => expect(view.dom.dataset.bridgeState).toBe("disconnected"));
  expect(view.state.doc.toString()).toBe("B");
  expect(postMessage).toHaveBeenCalledTimes(4);
  expect(postMessage.mock.calls.filter(([message]) => (message as { kind: string }).kind === "requestSnapshot")).toHaveLength(1);
});

test("ABA recovery retains a revert that equals the stale authoritative text", async () => {
  const failedEdit = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string; revision: number };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "transaction" && postMessage.mock.calls.length === 2) return failedEdit.promise;
    if (envelope.kind === "requestSnapshot") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 1, text: "B", selection: { anchor: 1, head: 1 } });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: envelope.revision });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
  view.dispatch({ changes: { from: 0, to: 1, insert: "A" }, selection: { anchor: 0 } });
  failedEdit.reject(new Error("ACK was lost after native commit"));

  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(4));
  expect(view.state.doc.toString()).toBe("A");
  expect(view.state.selection.main).toMatchObject({ anchor: 0, head: 0 });
  expect(postMessage.mock.calls[2]?.[0]).toMatchObject({ kind: "requestSnapshot", baseRevision: 0, revision: 0 });
  expect(postMessage.mock.calls[3]?.[0]).toMatchObject({ kind: "transaction", baseRevision: 1, revision: 2, payload: { text: "A", selection: { anchor: 0, head: 0 } } });
});

test("recovery snapshot equal to the latest ABA text sends selection only", async () => {
  const failedEdit = deferred<NativeReply>();
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string; revision: number };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "transaction" && postMessage.mock.calls.length === 2) return failedEdit.promise;
    if (envelope.kind === "requestSnapshot") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 1, text: "A", selection: { anchor: 1, head: 1 } });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: envelope.revision });
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
  view.dispatch({ changes: { from: 0, to: 1, insert: "A" }, selection: { anchor: 0 } });
  failedEdit.reject(new Error("ACK was lost"));

  await vi.waitFor(() => expect(postMessage).toHaveBeenCalledTimes(4));
  expect(view.state.doc.toString()).toBe("A");
  expect(view.state.selection.main).toMatchObject({ anchor: 0, head: 0 });
  expect(postMessage.mock.calls[3]?.[0]).toEqual({ kind: "selection", documentID: "doc", baseRevision: 1, revision: 1, payload: { selection: { anchor: 0, head: 0 } } });
  expect(postMessage.mock.calls.map(([message]) => message as { kind: string }).filter((message) => message.kind === "transaction")).toHaveLength(1);
});

test.each([
  ["rejected", () => Promise.reject(new Error("ready failed"))],
  ["invalid", () => Promise.resolve({ kind: "ack", documentID: "doc", revision: 0 })],
] as const)("%s ready reply enters an explicit safe disconnected state", async (_name, readyReply) => {
  const postMessage = vi.fn((_message: unknown) => readyReply());
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor("placeholder");
  const bridge = createNativeBridge(view);
  await bridge.ready;

  expect(view.state.doc.toString()).toBe("placeholder");
  expect(view.dom.dataset.bridgeState).toBe("disconnected");
  expect(view.contentDOM.contentEditable).toBe("false");
  view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: "unsent" } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(postMessage).toHaveBeenCalledOnce();
});

test.each([
  ["rejected", () => Promise.reject(new Error("snapshot failed"))],
  ["invalid", () => Promise.resolve({ kind: "snapshot", documentID: "other", revision: 1, text: "wrong", selection: { anchor: 0, head: 0 } })],
] as const)("%s recovery reply disconnects without discarding visible text or retrying", async (_name, recoveryReply) => {
  const postMessage = vi.fn((message: unknown) => {
    const envelope = message as { kind: string };
    if (envelope.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 1, head: 1 } });
    if (envelope.kind === "transaction") return Promise.reject(new Error("edit failed"));
    return recoveryReply();
  });
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });

  await vi.waitFor(() => expect(view.dom.dataset.bridgeState).toBe("disconnected"));
  expect(view.state.doc.toString()).toBe("B");
  expect(view.contentDOM.contentEditable).toBe("false");
  expect(postMessage).toHaveBeenCalledTimes(3);
  await new Promise((resolve) => setTimeout(resolve, 0));
  expect(postMessage).toHaveBeenCalledTimes(3);
});

test("new snapshots replace once without echo; stale is rejected and equal is idempotent", async () => {
  const postMessage = vi.fn(async () => ({ kind: "snapshot", documentID: "doc", revision: 2, text: "native", selection: { anchor: 6, head: 6 } }));
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const view = editor();
  const bridge = createNativeBridge(view);
  await bridge.ready;
  postMessage.mockClear();

  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 1, text: "stale", selection: { anchor: 0, head: 0 } })).toBe(false);
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 2, text: "native", selection: { anchor: 6, head: 6 } })).toBe(true);
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 3, text: "newer", selection: { anchor: 5, head: 5 } })).toBe(true);
  expect(view.state.doc.toString()).toBe("newer");
  expect(postMessage).not.toHaveBeenCalled();
});

test("wrong-document snapshots are rejected", async () => {
  const postMessage = vi.fn(async () => ({ kind: "snapshot", documentID: "doc", revision: 0, text: "native", selection: { anchor: 0, head: 0 } }));
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage } } } });
  const bridge = createNativeBridge(editor());
  await bridge.ready;
  expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "other", revision: 4, text: "attack", selection: { anchor: 0, head: 0 } })).toBe(false);
});

test("renderer-sanitized malicious Markdown cannot execute or call the bridge", async () => {
  const bridgeSpy = vi.fn();
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage: bridgeSpy } } } });
  const host = document.createElement("div");
  // Exact output is independently produced and asserted by test-editor-security.mjs.
  host.innerHTML = '<p><img src="x"></p>';
  document.body.append(host);
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(host.querySelector("script")).toBeNull();
  expect(host.querySelector("[onerror]")).toBeNull();
  expect(bridgeSpy).not.toHaveBeenCalled();
});

declare global {
  interface Window {
    fieldnotes: {
      applyNativeSnapshot(snapshot: unknown): boolean;
      setMode(mode: unknown): boolean;
      cycleMode(): void;
      setVimEnabled(enabled: unknown): boolean;
      toggleVim(): void;
      destroy(): void;
    };
  }
}

const schemaContext = { generation: 1, workspaceName: "notes", documentName: "note.md", assetPolicy: "workspace" as const, allowRemoteImages: false, mode: null, line: null, column: null, diagnostics: [], schema: {} };
function schemaHarness() {
  const first = deferred<NativeReply>(), second = deferred<NativeReply>();
  const deliveries: { revision: number; generation: number; state: string; accepted: boolean }[] = [];
  let nativeRevision = 0;
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, any>) {
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 0, head: 0 }, openContext: schemaContext });
    if (message.kind === "transaction") return ++nativeRevision === 1 ? first.promise : second.promise;
    if (message.kind === "schemaStatus") deliveries.push({ revision: message.revision, generation: message.payload.generation, state: message.payload.schemaState, accepted: message.revision === nativeRevision });
    return Promise.resolve({ kind: "ack", documentID: "doc", revision: nativeRevision });
  } } } } });
  const view = editor("A"), bridge = createNativeBridge(view);
  return { view, bridge, first, second, deliveries, revision: () => nativeRevision };
}

test("schema validation waits for its edit ACK and uses the accepted revision", async () => {
  const { view, bridge, first, deliveries, revision } = schemaHarness();
  try {
    await bridge.ready; bridge.postSchemaState("valid");
    await vi.waitFor(() => expect(deliveries).toHaveLength(1));
    view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
    await vi.waitFor(() => expect(revision()).toBe(1));
    bridge.postSchemaState("invalid");
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(deliveries).toEqual([{ revision: 0, generation: 1, state: "valid", accepted: true }]);
    first.resolve({ kind: "ack", documentID: "doc", revision: 1 });
    await vi.waitFor(() => expect(deliveries.at(-1)).toEqual({ revision: 1, generation: 1, state: "invalid", accepted: true }));
  } finally { bridge.destroy(); view.destroy(); }
});

test.each(["text", "context"] as const)("pending validation is discarded when $0 changes", async change => {
  const { view, bridge, first, second, deliveries, revision } = schemaHarness();
  try {
    await bridge.ready;
    view.dispatch({ changes: { from: 0, to: 1, insert: "B" } });
    await vi.waitFor(() => expect(revision()).toBe(1));
    bridge.postSchemaState("invalid");
    if (change === "text") view.dispatch({ changes: { from: 0, to: 1, insert: "C" } });
    else expect(window.fieldnotes.applyNativeSnapshot({ kind: "snapshot", documentID: "doc", revision: 0, text: "A", selection: { anchor: 0, head: 0 }, openContext: { ...schemaContext, generation: 2 } })).toBe(true);
    first.resolve({ kind: "ack", documentID: "doc", revision: 1 });
    if (change === "text") {
      await vi.waitFor(() => expect(revision()).toBe(2));
      second.resolve({ kind: "ack", documentID: "doc", revision: 2 });
    }
    await new Promise(resolve => setTimeout(resolve, 30));
    expect(deliveries).toEqual([]);
    bridge.postSchemaState("valid");
    await vi.waitFor(() => expect(deliveries).toEqual([{ revision: change === "text" ? 2 : 1, generation: change === "context" ? 2 : 1, state: "valid", accepted: true }]));
  } finally { bridge.destroy(); view.destroy(); }
});
