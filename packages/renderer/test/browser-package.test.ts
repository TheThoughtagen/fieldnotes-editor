import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { conformanceCases } from "../src/conformance.js";

describe("offline dist-only browser package", () => {
  let browser: Awaited<ReturnType<typeof chromium.launch>>;
  let closeServer: () => Promise<void>;
  let harnessUrl: string;
  let browserUrl: string;
  let notFoundCount = 0;

  beforeAll(async () => {
    const bundle = await readFile(new URL("../dist/browser.js", import.meta.url));
    const server = createServer((request, response) => {
      if (request.url === "/") {
        response.setHeader("content-type", "text/html");
        response.end("<!doctype html><main id=\"fixture\"></main>");
        return;
      }
      if (request.url !== "/browser.js") {
        notFoundCount += 1;
        response.statusCode = 404;
        response.end();
        return;
      }
      response.setHeader("access-control-allow-origin", "*");
      response.setHeader("content-type", "text/javascript");
      response.end(bundle);
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("Browser fixture server did not bind.");
    harnessUrl = `http://127.0.0.1:${address.port}/`;
    browserUrl = `${harnessUrl}browser.js`;
    closeServer = () => new Promise<void>((resolve, reject) =>
      server.close(error => error ? reject(error) : resolve())
    );
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await closeServer?.();
  }, 30_000);

  it("imports one self-contained bundle and hydrates without network access", async () => {
    const fixture = conformanceCases.find(candidate => candidate.name === "mermaid");
    if (fixture === undefined) throw new Error("Missing Mermaid conformance fixture.");
    const page = await browser.newPage();
    const requested: string[] = [];
    const blocked: string[] = [];
    const pageErrors: string[] = [];
    page.on("pageerror", error => pageErrors.push(error.message));
    await page.route("**/*", async route => {
      const url = route.request().url();
      requested.push(url);
      if (url === harnessUrl || url === browserUrl) await route.continue();
      else {
        blocked.push(url);
        await route.abort("blockedbyclient");
      }
    });

    await page.goto(harnessUrl);
    const result = await page.evaluate(async ({ moduleUrl, html }) => {
      const importModule = new Function("url", "return import(url)") as (url: string) => Promise<{
        hydrateMermaid(root: ParentNode): Promise<Array<{ status: string }>>;
        normalizeRenderedDom(root: ParentNode): string;
      }>;
      const api = await importModule(moduleUrl);
      const root = document.querySelector("#fixture");
      if (root === null) throw new Error("Missing fixture root.");
      root.innerHTML = html;
      const hydration = await api.hydrateMermaid(root);
      return {
        hydration,
        normalized: api.normalizeRenderedDom(root),
        svgCount: root.querySelectorAll("svg").length,
        errorCount: root.querySelectorAll("pre.fieldnotes-mermaid-error").length,
        unsafeCount: root.querySelectorAll("script, foreignObject, [onclick]").length,
        visibleText: root.textContent
      };
    }, { moduleUrl: browserUrl, html: fixture.expected.renderer.html });

    expect(result.hydration.map(({ status }: { status: string }) => status)).toEqual(["rendered", "error"]);
    expect(result.normalized).toBe(fixture.expected.hydratedDom);
    expect(result).toMatchObject({ svgCount: 1, errorCount: 1, unsafeCount: 0 });
    expect(result.visibleText).toContain("Observe");
    expect(result.visibleText).toContain("Act");
    expect(requested).toEqual([harnessUrl, browserUrl]);
    expect(blocked).toEqual([]);
    expect(pageErrors).toEqual([]);
    expect(notFoundCount).toBe(0);
    await page.close();
  }, 30_000);

  it("contains no bare module specifiers or split-chunk imports", async () => {
    const bundle = await readFile(new URL("../dist/browser.js", import.meta.url), "utf8");
    const specifiers = [...bundle.matchAll(
      /(?:\b(?:import|export)\s+(?:[^"']*?\s+from\s+)?|\bimport\(\s*)["']([^"']+)["']/gu
    )].map(match => match[1]);
    expect(specifiers).toEqual([]);
  });
});
