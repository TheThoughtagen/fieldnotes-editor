import { access, readFile, writeFile } from "node:fs/promises";

const manifest = JSON.parse(await readFile(new URL("../fixtures/manifest.json", import.meta.url), "utf8"));
if (!Array.isArray(manifest)) throw new TypeError("Fixture manifest must be an array.");

const names = new Set();
const cases = await Promise.all(manifest.map(async (entry) => {
  if (entry === null || typeof entry !== "object" || Array.isArray(entry)) {
    throw new TypeError("Every fixture manifest entry must be an object.");
  }
  const { name, options, images = [] } = entry;
  if (typeof name !== "string" || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/u.test(name)) {
    throw new TypeError(`Invalid fixture name: ${String(name)}`);
  }
  if (names.has(name)) throw new TypeError(`Duplicate fixture name: ${name}`);
  names.add(name);
  if (!Array.isArray(images) || images.some(image =>
    typeof image !== "string"
    || image.startsWith("/")
    || image.split("/").includes("..")
  )) {
    throw new TypeError(`Fixture ${name} has an invalid image path.`);
  }

  const fixtureUrl = new URL(`../fixtures/${name}/`, import.meta.url);
  const source = await readFile(new URL("index.md", fixtureUrl), "utf8");
  await Promise.all(images.map(async image => {
    if (!source.includes(`](${image}`)) {
      throw new TypeError(`Fixture ${name} does not reference listed image ${image}.`);
    }
    await access(new URL(image, fixtureUrl));
  }));
  const expected = JSON.parse(await readFile(new URL("expected.json", fixtureUrl), "utf8"));
  if (expected === null || typeof expected !== "object"
    || expected.renderer === null || typeof expected.renderer !== "object"
    || typeof expected.hydratedDom !== "string") {
    throw new TypeError(`Fixture ${name} has an invalid expected.json contract.`);
  }
  return {
    name,
    source,
    ...(options === undefined ? {} : { options }),
    expected
  };
}));
await writeFile(new URL("../src/conformance.generated.ts", import.meta.url),
  `export const generatedCases = ${JSON.stringify(cases, null, 2)} as const;\n`);
