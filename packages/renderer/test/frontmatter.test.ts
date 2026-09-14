import { describe, expect, it } from "vitest";
import { extractFrontmatter, validateFrontmatter, type JsonSchema } from "../src/index.js";

const schema: JsonSchema = {
  $schema: "https://json-schema.org/draft/2020-12/schema",
  type: "object",
  properties: {
    title: { type: "string" },
    date: { type: "string", format: "date" },
    draft: { type: "boolean" },
    tags: { type: "array", items: { type: "string" } }
  },
  required: ["title", "date"],
  additionalProperties: false
};

describe("frontmatter", () => {
  it("keeps an unquoted calendar date as a string and does not rewrite source", () => {
    const source = "---\ndate: 2026-09-14\ndraft: false\n---\nBody\n";

    expect(extractFrontmatter(source)).toMatchObject({
      data: { date: "2026-09-14", draft: false },
      body: "Body\n",
      source
    });
  });

  it("parses quoted dates, booleans, and arrays with YAML 1.2 core values", () => {
    const result = extractFrontmatter(
      "---\ndate: '2028-02-29'\ndraft: true\ntags: [editor, markdown]\n---\n"
    );

    expect(result.diagnostics).toEqual([]);
    expect(result.data).toEqual({
      date: "2028-02-29",
      draft: true,
      tags: ["editor", "markdown"]
    });
  });

  it("reports malformed, missing, unclosed, and non-object frontmatter without throwing", () => {
    const sources = [
      "Body without frontmatter\n",
      "---\ntitle: unfinished\n",
      "---\ntitle: [\n---\nBody\n",
      "---\n- not\n- an object\n---\nBody\n"
    ];

    for (const source of sources) {
      expect(() => extractFrontmatter(source)).not.toThrow();
      expect(extractFrontmatter(source).diagnostics).toEqual([
        expect.objectContaining({ severity: "error", position: { line: 1, column: 1 } })
      ]);
    }
  });

  it("returns schema diagnostics for additional properties and invalid values", () => {
    const additionalPropertyDiagnostics = validateFrontmatter(
      { title: "x", date: "2028-02-29", sample: true },
      schema
    );
    const invalidDateDiagnostics = validateFrontmatter(
      { title: "x", date: "2026-02-29" },
      schema
    );
    const impossibleMonthDiagnostics = validateFrontmatter(
      { title: "x", date: "2026-99-99" },
      schema
    );

    expect(additionalPropertyDiagnostics).toEqual(expect.arrayContaining([
      expect.objectContaining({ code: "schema.additionalProperties", severity: "error" })
    ]));
    expect(invalidDateDiagnostics).toEqual(expect.arrayContaining([
      expect.objectContaining({ code: "schema.format", message: "/date must match format \"date\"" })
    ]));
    expect(impossibleMonthDiagnostics).toEqual(expect.arrayContaining([
      expect.objectContaining({ code: "schema.format", message: "/date must match format \"date\"" })
    ]));
    expect(validateFrontmatter({ title: "x", date: "2028-02-29" }, schema)).toEqual([]);
  });
});
