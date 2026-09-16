import { expect, test } from "vitest";
import { documentSearchEntries } from "../src/index.js";

test("search entries share Markdown parsing and retain exact original source lines", () => {
  const source = "---\ntags: [Calibration]\n---\nCalibration in prose.\n\nCalibration\n-----------\n\n## Use **safe** defaults\n\n[Handbook][docs]\n\n[docs]: https://example.test\n\n```md\n## Hidden\n[Hidden][docs]\n```\n\n[Missing][absent]";
  expect(documentSearchEntries(source)).toEqual([
    { kind: "tag", title: "Calibration", line: 2 },
    { kind: "heading", title: "Calibration", line: 6 },
    { kind: "heading", title: "Use safe defaults", line: 9 },
    { kind: "link", title: "Handbook", line: 11 },
  ]);
});
