import { afterEach, expect, test, vi } from "vitest";
import { createEditor, type EditorController } from "../src/editor.js";
let editor: EditorController | undefined;
afterEach(() => { editor?.destroy(); delete (window as Window & { webkit?: unknown }).webkit; document.body.replaceChildren(); });
const context = { generation: 1, workspaceName: "notes", documentName: "note.md", assetPolicy: "workspace", mode: "source", line: 2, column: 2, diagnostics: ["configuration notice"], schema: { type: "object", required: ["title"] } };
function snapshot(openContext = context) { return { kind: "snapshot", documentID: "doc", revision: 0, text: "# First\nsecond", selection: { anchor: 0, head: 0 }, openContext }; }
test("native schema, mode and position apply once and diagnostics remain visible while editing", async () => {
  const messages: Record<string, unknown>[] = [];
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { async postMessage(message: Record<string, unknown>) { messages.push(message); return message.kind === "ready" ? snapshot() : { kind: "ack", documentID: "doc", revision: 0 }; } } } } });
  const root = document.createElement("main"); document.body.append(root); editor = createEditor(root);
  await vi.waitFor(() => expect(editor?.mode).toBe("source"));
  expect(editor.view.state.selection.main.head).toBe(9);
  await vi.waitFor(() => expect(root.querySelector(".fieldnotes-diagnostics")?.textContent).toContain("title"));
  expect(root.querySelector(".fieldnotes-diagnostics")?.textContent).toContain("configuration notice");
  editor.setMode("focus");
  editor.view.dispatch({ selection: { anchor: 11 } });
  expect(window.fieldnotes.applyNativeSnapshot(snapshot())).toBe(true);
  expect(editor.mode).toBe("focus");
  expect(editor.view.state.selection.main.head).toBe(11);
  expect(messages.some(message => message.kind === "contextApplied")).toBe(true);
  expect(window.fieldnotes.applyNativeSnapshot(snapshot({ ...context, generation: 2, mode: "preview" }))).toBe(true);
  expect(editor.mode).toBe("preview");
});
