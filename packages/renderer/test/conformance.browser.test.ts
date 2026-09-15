import { describe, expect, it } from "vitest";
import { hydrateMermaid, normalizeRenderedDom } from "../src/browser.js";
import { conformanceCases } from "../src/conformance.js";

describe("literal hydrated DOM conformance corpus", () => {
  for (const fixture of conformanceCases) {
    it(`matches the complete ${fixture.name} browser contract`, async () => {
      const container = document.createElement("main");
      container.id = "fixture";
      container.innerHTML = fixture.expected.renderer.html;
      document.body.append(container);
      try {
        await hydrateMermaid(container);
        expect(normalizeRenderedDom(container)).toBe(fixture.expected.hydratedDom);
        if (fixture.name === "mermaid") {
          expect(container.textContent).toContain("Observe");
          expect(container.textContent).toContain("Act");
        }
      } finally {
        container.remove();
      }
    });
  }
});
