import { describe, expect, it } from "vitest";
import { conformanceCases } from "../src/conformance.js";
import { renderDocument } from "../src/index.js";

describe("literal renderer conformance corpus", () => {
  it("contains every reviewed fixture", () => {
    expect(conformanceCases.map(fixture => fixture.name)).toEqual([
      "kitchen-sink",
      "unsafe-html",
      "malformed",
      "mermaid"
    ]);
  });

  for (const fixture of conformanceCases) {
    it(`matches the complete ${fixture.name} renderer contract`, async () => {
      const actual = await renderDocument(fixture.source, fixture.options);
      expect(actual).toEqual(fixture.expected.renderer);
    });
  }
});
