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

test("semantic theme tokens color syntax, headings and gutters without changing editor state", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  const root = document.querySelector<HTMLElement>("#editor")!;
  const editor = createEditor(root, { initialDocument: '# Heading\n\n```html\n<!-- Comment -->\n<p class="example">Hello</p>\n```' });
  const style = document.documentElement.style;
  try {
    editor.setMode('source');
    await expect.poll(() => root.querySelector('.cm-content')?.textContent).toContain('Comment');
    await new Promise(resolve => setTimeout(resolve, 150));
    const state = editor.view.state, view = editor.view;
    style.setProperty('--fn-gutter', '#123456');
    style.setProperty('--fn-paper', '#182828');
    style.setProperty('--fn-heading', '#abcdef');
    style.setProperty('--fn-comment', '#fedcba');
    expect(getComputedStyle(root.querySelector('.cm-gutters')!).backgroundColor).toBe('rgb(18, 52, 86)');
    await expect.poll(() => [...root.querySelectorAll('.cm-content span')].some(span => getComputedStyle(span).color === 'rgb(254, 220, 186)')).toBe(true);
    expect(editor.view).toBe(view); expect(editor.view.state).toBe(state);
    editor.setMode('focus');
    expect(getComputedStyle(root.querySelector('.fn-atxheading1')!).color).toBe('rgb(171, 205, 239)');
    const gutter = root.querySelector('.cm-gutters');
    expect(!gutter || getComputedStyle(gutter).display === 'none').toBe(true);
  } finally { for (const key of ['gutter','paper','heading','comment']) style.removeProperty(`--fn-${key}`); editor.destroy(); }
});
