import assert from "node:assert/strict";
import { createReadStream, existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, relative, resolve, sep } from "node:path";
import { chromium } from "@playwright/test";

const repositoryRoot = resolve(import.meta.dirname, "..");
const bundleRoot = join(repositoryRoot, "build", "editor-web");
assert.ok(existsSync(join(bundleRoot, "index.html")), "editor-web bundle must exist before offline verification");

const mimeTypes = new Map([
  [".css", "text/css"],
  [".html", "text/html"],
  [".js", "text/javascript"],
  [".json", "application/json"],
  [".svg", "image/svg+xml"],
  [".woff2", "font/woff2"],
]);

function localFile(pathname) {
  const decoded = decodeURIComponent(pathname === "/" ? "/index.html" : pathname);
  const candidate = normalize(join(bundleRoot, decoded));
  assert.ok(candidate === bundleRoot || candidate.startsWith(`${bundleRoot}${sep}`), `path escaped bundle: ${pathname}`);
  return candidate;
}

const server = createServer((request, response) => {
  try {
    const file = localFile(new URL(request.url ?? "/", "http://localhost").pathname);
    if (!existsSync(file) || !statSync(file).isFile()) {
      response.writeHead(404).end("not found");
      return;
    }
    response.writeHead(200, { "content-type": mimeTypes.get(extname(file)) ?? "application/octet-stream" });
    createReadStream(file).pipe(response);
  } catch (error) {
    response.writeHead(400).end(String(error));
  }
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const address = server.address();
assert.ok(address && typeof address === "object");
const origin = `http://127.0.0.1:${address.port}`;
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
const failures = [];

page.on("console", (message) => {
  if (message.type() === "error") failures.push(`console: ${message.text()}`);
});
page.on("pageerror", (error) => failures.push(`page: ${error.message}`));
page.on("request", (request) => {
  const url = new URL(request.url());
  if (url.origin !== origin) failures.push(`external request: ${request.url()}`);
});
page.on("response", (response) => {
  if (response.url().startsWith(origin) && !response.ok()) failures.push(`${response.status()} ${response.url()}`);
});
await page.route("**/*", async (route) => {
  const requestOrigin = new URL(route.request().url()).origin;
  if (requestOrigin !== origin) {
    failures.push(`blocked external request: ${route.request().url()}`);
    await route.abort("blockedbyclient");
    return;
  }
  await route.continue();
});

function emittedFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    return entry.isDirectory() ? emittedFiles(path) : [path];
  });
}

function emittedReferences(file) {
  const text = readFileSync(file, "utf8");
  const patterns = extname(file) === ".html"
    ? [/(?:src|href)="([^"]+)"/g]
    : extname(file) === ".css"
      ? [/url\(["']?([^"')]+)["']?\)/g, /@import\s+["']([^"']+)["']/g]
      : extname(file) === ".js"
        ? [/(?:import\s*(?:\(|)["']|from\s*["'])([^"']+)["']/g]
        : [];
  return patterns.flatMap((pattern) => Array.from(text.matchAll(pattern), (match) => match[1]));
}

try {
  await page.goto(origin, { waitUntil: "networkidle" });
  await page.locator("#editor[data-booted=true]").waitFor({ state: "attached" });
  assert.deepEqual(failures, []);

  let referenceCount = 0;
  for (const file of emittedFiles(bundleRoot)) {
    for (const reference of emittedReferences(file)) {
      if (reference.startsWith("data:") || reference.startsWith("#")) continue;
      referenceCount += 1;
      assert.ok(!/^(?:https?:)?\/\//.test(reference), `external bundle reference in ${relative(bundleRoot, file)}: ${reference}`);
      assert.ok(reference.startsWith(".") || reference.startsWith("/"), `bare bundle import in ${relative(bundleRoot, file)}: ${reference}`);
      const containingURL = new URL(relative(bundleRoot, file), `${origin}/`);
      const target = localFile(new URL(reference, containingURL).pathname);
      assert.ok(existsSync(target), `missing bundle reference from ${relative(bundleRoot, file)}: ${relative(bundleRoot, target)}`);
    }
  }
  assert.ok(referenceCount > 0, "bundle graph must reference emitted assets");
} finally {
  await page.close();
  await browser.close();
  await new Promise((resolveClose, rejectClose) => server.close((error) => error ? rejectClose(error) : resolveClose()));
}
