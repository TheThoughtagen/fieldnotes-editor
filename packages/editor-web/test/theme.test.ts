import { expect, test } from "vitest";
import { createEditor } from "../src/editor.js";

test("prose and source use deliberate typography and Focus decorations reach whole blocks", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: '# Heading\n\nA **strong** and *quiet* `value`.\n\n> First\n> Second\n\n```js\nconst value = 42;\nconsole.log(value);\n```\n\n| Name | Value |\n| --- | --- |\n| Oak | 42 |' });
  try {
    expect(getComputedStyle(root.querySelector('.cm-content')!).fontFamily).toContain('system-ui');
    expect(getComputedStyle(root.querySelector('.fn-atxheading1 span')!).textDecorationLine).toBe('none');
    expect(root.querySelectorAll('.fn-fencedcode').length).toBe(4);
    expect(root.querySelectorAll('.fn-blockquote').length).toBe(2);
    expect(getComputedStyle(root.querySelector('.fn-inlinecode')!).backgroundColor).not.toBe('rgba(0, 0, 0, 0)');
    const proseSize = parseFloat(getComputedStyle(root.querySelector('.cm-content')!).fontSize);
    editor.setMode('source');
    expect(parseFloat(getComputedStyle(root.querySelector('.cm-content')!).fontSize)).toBeLessThan(proseSize);
    editor.setMode('preview');
    await expect.poll(() => root.querySelector('article table')).toBeTruthy();
    expect(getComputedStyle(root.querySelector('article')!).fontSize).toBe(`${proseSize}px`);
    expect(getComputedStyle(root.querySelector('article th')!).borderBottomStyle).toBe('solid');
  } finally { editor.destroy(); }
});


test("YAML metadata stays compact rather than becoming a Setext heading", () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: '---\ntitle: Workshop notes\n---\n\n# Real heading' });
  try {
    expect(root.querySelectorAll('.fn-frontmatter-line').length).toBe(3);
    expect(root.querySelector('.fn-setextheading2')).toBeNull();
    const metadata = root.querySelectorAll('.fn-frontmatter-line')[1]!;
    expect(getComputedStyle(metadata).fontSize).toBe('13px');
    for (const span of metadata.querySelectorAll('span')) expect(getComputedStyle(span).fontWeight).toBe('400');
    editor.view.dispatch({selection:{anchor:editor.view.state.doc.length}});
    expect(getComputedStyle(metadata).fontSize).toBe('13px');
  } finally { editor.destroy(); }
});

test("all Mermaid diagram types get a readable surface and mixed lists preserve their markers", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: '---\ntitle: Diagram review\n---\n\n1. [x] Done\n2. Ordered step\n\n- [x] Done\n- Unordered step\n\n```mermaid\nsequenceDiagram\nAlice->>Bob: Hello\nBob-->>Alice: Hi\n```' });
  try {
    editor.setMode('preview');
    await expect.poll(() => root.querySelector('article svg')).toBeTruthy();
    const diagram = root.querySelector('article svg')!;
    expect(diagram.classList.contains('flowchart')).toBe(false);
    expect(getComputedStyle(diagram).backgroundColor).toBe('rgb(248, 250, 252)');
    expect(diagram.getBoundingClientRect().width).toBeLessThanOrEqual(root.getBoundingClientRect().width);
    expect(getComputedStyle(root.querySelector('ol > li:not(.task-list-item)')!).listStyleType).toBe('decimal');
    expect(getComputedStyle(root.querySelector('ul > li:not(.task-list-item)')!).listStyleType).toBe('disc');
    for (const item of root.querySelectorAll('.task-list-item')) expect(getComputedStyle(item).listStyleType).toBe('none');
  } finally { editor.destroy(); }
});
