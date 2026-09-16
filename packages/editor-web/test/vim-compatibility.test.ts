import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import { createEditor } from "../src/editor.js";

test.each([
  { keys: "dw", source: "one two", expected: "two" },
  { keys: "dd", source: "one\ntwo", expected: "two" },
  { keys: "2x", source: "abcd", expected: "cd" },
])("supported Vim command $keys has an exact document outcome", async ({ keys, source, expected }) => {
  document.body.innerHTML = '<main id="editor"></main>';
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: source });
  editor.view.focus();
  await userEvent.keyboard(keys);
  expect(editor.view.state.doc.toString()).toBe(expected);
  editor.destroy();
});

test("Markdown-aware dit operates only on the innermost HTML tag", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const source = '<section><em class="x">word</em></section>';
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: source });
  editor.view.dispatch({ selection: { anchor: source.indexOf("word") } });
  editor.view.focus();
  await userEvent.keyboard("dit");
  expect(editor.view.state.doc.toString()).toBe('<section><em class="x"></em></section>');
  editor.destroy();
});

test("unsupported :map leaves the document unchanged and reports a visible diagnostic", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "unchanged" });
  editor.view.focus();
  await userEvent.keyboard(":map jj kk{Enter}");
  expect(editor.view.state.doc.toString()).toBe("unchanged");
  expect(document.querySelector(".fieldnotes-vim-diagnostic")?.textContent).toContain("Unsupported Vim command");
  editor.destroy();
});
