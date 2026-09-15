import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const run = promisify(execFile);

describe("package contract", () => {
  it("is a public ESM package with node and browser entries", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
    expect(pkg).toMatchObject({
      name: "@cruciblesoftware/fieldnotes-renderer",
      version: "0.1.0",
      type: "module",
      engines: { node: ">=24" },
      publishConfig: { access: "public", provenance: true }
    });
    expect(Object.keys(pkg.exports)).toEqual([".", "./browser", "./conformance", "./styles.css"]);
    expect(pkg.files).toEqual(["dist/*.js", "dist/*.d.ts", "dist/styles.css", "fixtures"]);
    expect(pkg.scripts.prepack).toBe("npm run build");
  });

  it("generates declarations separately from the JavaScript bundles", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));

    expect(pkg.scripts.build).toContain("build:types");
    expect(pkg.scripts["build:types"]).toBe("tsc --emitDeclarationOnly");
    expect(pkg.scripts.build).not.toContain("tsup");
    expect(pkg.scripts["build:node"]).not.toContain("--sourcemap");
    expect(pkg.scripts["build:node"]).toContain("--packages=external");
    expect(pkg.scripts["build:browser"]).not.toContain("--sourcemap");

    const tsconfig = JSON.parse(await readFile(new URL("../tsconfig.json", import.meta.url), "utf8"));
    expect(tsconfig.compilerOptions).toMatchObject({ declarationMap: false, sourceMap: false });
  });

  it("keeps bundled Mermaid tooling out of the production dependency tree", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
    expect(pkg.dependencies).not.toHaveProperty("mermaid");
    expect(pkg.devDependencies.mermaid).toBe("12.0.0");

    const repositoryRoot = fileURLToPath(new URL("../../..", import.meta.url));
    const { stdout } = await run("npm", [
      "ls", "--omit=dev", "--all", "--json"
    ], { cwd: repositoryRoot });
    expect(stdout).not.toMatch(/"(?:mermaid|chevrotain|lodash-es)":/u);
  });

  it("imports every built JavaScript export and renders through dist", async () => {
    const nodeEntry = await import(new URL("../dist/index.js", import.meta.url).href);
    const browserEntry = await import(new URL("../dist/browser.js", import.meta.url).href);
    const conformanceEntry = await import(new URL("../dist/conformance.js", import.meta.url).href);

    expect(browserEntry).toBeTypeOf("object");
    expect(conformanceEntry).toBeTypeOf("object");
    const rendered = await nodeEntry.renderDocument("---\ntitle: Built\n---\n## Works\n");
    expect(rendered.toc).toEqual([{ depth: 2, id: "works", text: "Works", children: [] }]);
    expect(rendered.html).toContain('<h2 id="works">Works</h2>');
  }, 30_000);

  it("emits every exported import, type, and stylesheet target", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
    const targets = Object.values(pkg.exports).flatMap((entry) =>
      typeof entry === "string" ? [entry] : Object.values(entry)
    );

    await Promise.all(targets.map((target) =>
      access(new URL(`../${target.slice(2)}`, import.meta.url))
    ));
  });
});
