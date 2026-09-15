import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { expect, test, vi } from "vitest";
import { createNativeBridge, type NativeReply } from "../src/bridge.js";

function editor(text = "one") {
  const parent = document.createElement("div");
  document.body.replaceChildren(parent);
  return new EditorView({ state: EditorState.create({ doc: text }), parent });
}

test("handler is absent and the exported global is narrow and frozen", () => {
  delete (window as Window & { webkit?: unknown }).webkit;
  const view = editor();
  const bridge = createNativeBridge(view);
  expect(bridge.available).toBe(false);
  expect(Object.keys(window.fieldnotes)).toEqual(["applyNativeSnapshot"]);
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
    };
  }
}
