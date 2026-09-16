import { expect, test } from "vitest";
import { EditorState } from "@codemirror/state";
import { markdown } from "@codemirror/lang-markdown";
import { locateMarkdownTagObject } from "../src/markdown-tag-object.js";

function locate(source: string, needle: string, around = false) {
  const state = EditorState.create({ doc: source, extensions: markdown() });
  return locateMarkdownTagObject(state, source.indexOf(needle), around);
}

test("tag object chooses the innermost nested element with attributes", () => {
  const source = '<section class="outer"><em data-x=">">word</em></section>';
  const inner = locate(source, "word");
  expect(source.slice(inner?.from, inner?.to)).toBe("word");
  const around = locate(source, "word", true);
  expect(source.slice(around?.from, around?.to)).toBe('<em data-x=">">word</em>');
});

test("tag object is limited to Markdown Paragraph or HTMLBlock nodes", () => {
  expect(locate("Before <mark>text</mark> after", "text")).toEqual({ from: 13, to: 17 });
  expect(locate("```html\n<div>code</div>\n```", "code")).toBeUndefined();
  expect(locate("plain paragraph", "plain")).toBeUndefined();
});
