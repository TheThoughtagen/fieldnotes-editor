import { readFile, writeFile } from "node:fs/promises";

const manifest = JSON.parse(await readFile(new URL("../fixtures/manifest.json", import.meta.url), "utf8"));
const cases = await Promise.all(manifest.map(async ({ name }) => ({
  name,
  source: await readFile(new URL(`../fixtures/${name}/index.md`, import.meta.url), "utf8"),
  expected: JSON.parse(await readFile(new URL(`../fixtures/${name}/expected.json`, import.meta.url), "utf8"))
})));
await writeFile(new URL("../src/conformance.generated.ts", import.meta.url),
  `export const generatedCases = ${JSON.stringify(cases, null, 2)} as const;\n`);
