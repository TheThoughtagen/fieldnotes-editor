import { expect, test } from "vitest";

test("boots the actual entry point into one editor root", async () => {
  document.body.innerHTML = '<main id="editor" aria-label="Markdown editor"></main>';

  await import("../src/main.js");

  const roots = document.querySelectorAll<HTMLElement>("#editor");
  expect(roots).toHaveLength(1);
  expect(roots[0]?.dataset.booted).toBe("true");
  expect(roots[0]?.getAttribute("role")).toBe("application");
});
