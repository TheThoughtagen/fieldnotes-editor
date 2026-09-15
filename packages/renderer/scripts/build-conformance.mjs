import { readFile, stat, writeFile } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const fixturesUrl = process.argv[2] === undefined
  ? new URL("../fixtures/", import.meta.url)
  : pathToFileURL(`${resolve(process.argv[2])}${sep}`);
const outputUrl = process.argv[3] === undefined
  ? new URL("../src/conformance.generated.ts", import.meta.url)
  : pathToFileURL(resolve(process.argv[3]));
const manifest = JSON.parse(await readFile(new URL("manifest.json", fixturesUrl), "utf8"));
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
    || image.length === 0
  )) {
    throw new TypeError(`Fixture ${name} has an invalid image path.`);
  }

  const fixtureUrl = new URL(`${name}/`, fixturesUrl);
  const source = await readFile(new URL("index.md", fixtureUrl), "utf8");
  await Promise.all(images.map(async image => {
    if (!source.includes(`](${image}`)) {
      throw new TypeError(`Fixture ${name} does not reference listed image ${image}.`);
    }
    let imageUrl;
    try {
      imageUrl = new URL(image, fixtureUrl);
    } catch {
      throw new TypeError(`Fixture ${name} image ${image} resolves outside its fixture directory.`);
    }
    const fixturePath = fileURLToPath(fixtureUrl);
    if (imageUrl.protocol !== "file:") {
      throw new TypeError(`Fixture ${name} image ${image} resolves outside its fixture directory.`);
    }
    const imagePath = fileURLToPath(imageUrl);
    const relativePath = relative(fixturePath, imagePath);
    if (relativePath === ".." || relativePath.startsWith(`..${sep}`) || isAbsolute(relativePath)) {
      throw new TypeError(`Fixture ${name} image ${image} resolves outside its fixture directory.`);
    }
    if (!(await stat(imagePath)).isFile()) {
      throw new TypeError(`Fixture ${name} image ${image} is not a file.`);
    }
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
await writeFile(outputUrl,
  `export const generatedCases = ${JSON.stringify(cases, null, 2)} as const;\n`);
