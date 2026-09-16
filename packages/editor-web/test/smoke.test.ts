import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";

test("boots one reusable CodeMirror editor with Vim enabled", async () => {
  document.body.innerHTML = '<main id="editor" aria-label="Markdown editor"></main>';

  const { bootEditor } = await import("../src/main.js");

  const roots = document.querySelectorAll<HTMLElement>("#editor");
  expect(roots).toHaveLength(1);
  expect(roots[0]?.dataset.booted).toBe("true");
  expect(roots[0]?.getAttribute("role")).toBeNull();

  const originalEditor = roots[0]?.querySelector<HTMLElement>(".cm-editor");
  expect(originalEditor).not.toBeNull();
  expect(roots[0]?.querySelectorAll(".cm-content")).toHaveLength(1);
  expect(roots[0]?.querySelector(".cm-scroller")?.classList.contains("cm-vimMode")).toBe(true);

  const content = roots[0]?.querySelector<HTMLElement>(".cm-content");
  await userEvent.click(content!);
  await userEvent.keyboard("ix");
  expect(content?.textContent).not.toBe("# FIELDNOTES");
  expect(content?.textContent).toContain("x");
  expect(roots[0]?.querySelector(".cm-scroller")?.classList.contains("cm-vimMode")).toBe(false);

  bootEditor(roots[0]!);
  expect(roots[0]?.querySelectorAll(".cm-editor")).toHaveLength(1);
  expect(originalEditor?.isConnected).toBe(false);
});
