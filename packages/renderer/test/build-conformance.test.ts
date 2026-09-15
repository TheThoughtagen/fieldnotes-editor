import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";

const run = promisify(execFile);
const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map(directory =>
    rm(directory, { recursive: true, force: true })
  ));
});

describe("conformance corpus generation", () => {
  it("reproduces the checked-in generated module exactly", async () => {
    const directory = await makeTemporaryDirectory();
    const output = join(directory, "conformance.generated.ts");
    await run(process.execPath, [
      fileURLToPath(new URL("../scripts/build-conformance.mjs", import.meta.url)),
      fileURLToPath(new URL("../fixtures/", import.meta.url)),
      output
    ]);

    const [actual, expected] = await Promise.all([
      readFile(output, "utf8").catch(() => null),
      readFile(new URL("../src/conformance.generated.ts", import.meta.url), "utf8")
    ]);
    expect(actual).toBe(expected);
  });

  for (const image of ["%2e%2e/secret.svg", "file:///tmp/secret.svg"]) {
    it(`rejects resolved image paths outside the fixture: ${image}`, async () => {
      const directory = await makeTemporaryDirectory();
      const fixture = join(directory, "fixtures", "escape");
      await mkdir(fixture, { recursive: true });
      await writeFile(join(directory, "fixtures", "manifest.json"), JSON.stringify([{
        name: "escape",
        images: [image]
      }]));
      await writeFile(join(fixture, "index.md"), `![escape](${image})\n`);
      await writeFile(join(fixture, "expected.json"), JSON.stringify({
        renderer: {},
        hydratedDom: ""
      }));

      const result = await run(process.execPath, [
        fileURLToPath(new URL("../scripts/build-conformance.mjs", import.meta.url)),
        join(directory, "fixtures"),
        join(directory, "output.ts")
      ]).then(
        () => ({ code: 0, stderr: "" }),
        error => ({ code: error.code as number, stderr: String(error.stderr) })
      );
      expect(result.code).not.toBe(0);
      expect(result.stderr).toContain("outside its fixture directory");
    });
  }
});

async function makeTemporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "fieldnotes-conformance-"));
  temporaryDirectories.push(directory);
  return directory;
}
