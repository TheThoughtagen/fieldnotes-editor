import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { generateVimCompatibility, validateVimCompatibility } from "./generate-vim-docs.mjs";

const root = new URL("../", import.meta.url);
const matrix = JSON.parse(await readFile(new URL("vim-compatibility.json", root), "utf8"));
const tokenManifest = JSON.parse(await readFile(new URL("vim-token-manifest.json", root), "utf8"));
const requiredSpecTokens = { put: ["p", "P"] };

test("matrix is closed, complete, and uniquely keyed", () => {
  const summary = validateVimCompatibility(matrix);
  assert.equal(summary.total, matrix.commands.length);
  assert.ok(summary.supported > 0);
  assert.ok(summary.adapted > 0);
  assert.ok(summary.unsupported > 0);
});

test("generated documentation is byte-for-byte deterministic", async () => {
  const expected = await readFile(new URL("docs/vim-compatibility.md", root), "utf8");
  assert.equal(generateVimCompatibility(matrix), expected);
  assert.ok(expected.endsWith("\n"));
  assert.ok(!expected.endsWith("\n\n"));
  assert.doesNotMatch(expected, /generated at|timestamp/iu);
});

test("hardcoded Vim spec baseline includes required put commands", () => {
  for (const [row, tokens] of Object.entries(requiredSpecTokens)) {
    assert.deepEqual(tokenManifest[row], tokens);
  }
});
