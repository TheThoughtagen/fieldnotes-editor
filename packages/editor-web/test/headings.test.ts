import { expect, test } from "vitest";
import { undo, redo } from "@codemirror/commands";
import { getCM } from "@replit/codemirror-vim";
import { createEditor } from "../src/editor.js";

const source = "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\nSetext one\n==========\n\nSetext two\n----------\n\nBody text\n";
const mount = () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const root = document.querySelector<HTMLElement>("#editor")!;
  return { root, editor: createEditor(root, { initialDocument: source }) };
};
const line = (root: HTMLElement, text: string) => [...root.querySelectorAll<HTMLElement>(".cm-line")].find(element => element.textContent === text)!;
const size = (element: Element) => parseFloat(getComputedStyle(element).fontSize);

test("Focus renders a bounded heading hierarchy for ATX and Setext; Source restores body sizing", () => {
  const { root, editor } = mount();
  try {
    const body = size(line(root, "Body text"));
    const headings = ["# One", "## Two", "### Three", "#### Four", "##### Five", "###### Six"];
    const sizes = headings.map(text => size(line(root, text)));
    expect(sizes[0]).toBeGreaterThan(body * 1.5);
    expect(sizes[0]).toBeLessThanOrEqual(body * 2);
    sizes.forEach((value, index) => {
      expect(value).toBeGreaterThanOrEqual(body);
      if (index) expect(value).toBeLessThan(sizes[index - 1]!);
      expect(parseInt(getComputedStyle(line(root, headings[index]!)).fontWeight)).toBeGreaterThanOrEqual(600);
    });
    expect(size(line(root, "Setext one"))).toBe(sizes[0]);
    expect(size(line(root, "Setext two"))).toBe(sizes[1]);
    editor.setMode("source");
    [...headings, "Setext one", "Setext two"].forEach(text => expect(size(line(root, text))).toBe(body));
    editor.setMode("focus");
    expect(size(line(root, "# One"))).toBe(sizes[0]);
  } finally { editor.destroy(); }
});

test("heading punctuation reveals at the cursor while toggles preserve document, selection, Vim and history", () => {
  const { root, editor } = mount();
  try {
    const view = editor.view;
    const adapter = getCM(view);
    const mark = () => line(root, "# One").querySelector<HTMLElement>(".fn-syntax-active, .fn-syntax-muted")!;
    expect(getComputedStyle(mark()).opacity).toBe("1");
    view.dispatch({ changes: { from: source.length, insert: "Edited" }, selection: { anchor: source.indexOf("Body"), head: source.indexOf("Body") + 4 } });
    expect(getComputedStyle(mark()).opacity).toBe("0.3");
    const text = view.state.doc.toString();
    const selection = view.state.selection.toJSON();
    for (const mode of ["source", "preview", "focus"] as const) editor.setMode(mode);
    expect(editor.view).toBe(view);
    expect(view.state.doc.toString()).toBe(source + "Edited");
    expect(view.state.selection.toJSON()).toEqual(selection);
    expect(getCM(view)).toBe(adapter);
    expect(editor.vimEnabled).toBe(true);
    expect(undo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(source);
    expect(redo(view)).toBe(true);
    expect(view.state.doc.toString()).toBe(text);
    view.dispatch({ selection: { anchor: source.indexOf("Setext one") } });
    const underline = line(root, "==========").querySelector<HTMLElement>(".fn-syntax-active")!;
    expect(getComputedStyle(underline).opacity).toBe("1");
  } finally { editor.destroy(); }
});

test("Preview retains semantic, visibly differentiated h1 through h6 and Setext headings", async () => {
  const { root, editor } = mount();
  try {
    editor.setMode("preview");
    await expect.poll(() => root.querySelectorAll("article h1, article h2, article h3, article h4, article h5, article h6").length).toBe(8);
    const headings = Array.from({ length: 6 }, (_, index) => root.querySelector(`article h${index + 1}`)!);
    expect(headings.map(element => element.textContent)).toEqual(["One", "Two", "Three", "Four", "Five", "Six"]);
    headings.forEach((element, index) => {
      expect(element.getBoundingClientRect().height).toBeGreaterThan(0);
      expect(parseInt(getComputedStyle(element).fontWeight)).toBeGreaterThanOrEqual(600);
      if (index) expect(size(element)).toBeLessThan(size(headings[index - 1]!));
    });
    expect(root.querySelectorAll("article h1")[1]?.textContent).toBe("Setext one");
    expect(root.querySelectorAll("article h2")[1]?.textContent).toBe("Setext two");
    expect(editor.view.state.doc.toString()).toBe(source);
  } finally { editor.destroy(); }
});
