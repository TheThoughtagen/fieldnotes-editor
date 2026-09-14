import { access, readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

describe("package contract", () => {
  it("is a public ESM package with node and browser entries", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
    expect(pkg).toMatchObject({
      name: "@thethoughtagen/fieldnotes-renderer",
      version: "0.1.0",
      type: "module",
      engines: { node: ">=24" },
      publishConfig: { access: "public" }
    });
    expect(Object.keys(pkg.exports)).toEqual([".", "./browser", "./conformance", "./styles.css"]);
  });

  it("generates declarations separately from the JavaScript bundles", async () => {
    const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));

    expect(pkg.scripts.build).toContain("build:types");
    expect(pkg.scripts["build:types"]).toBe("tsc --emitDeclarationOnly");
    expect(pkg.scripts.build).not.toContain("tsup");
    expect(pkg.scripts["build:node"]).toContain("--sourcemap");
    expect(pkg.scripts["build:browser"]).toContain("--sourcemap");
  });

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
