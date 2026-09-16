import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = new URL("../", import.meta.url);
const required = JSON.parse(await readFile(new URL("vim-required-commands.json", root), "utf8"));
const tokenManifest = JSON.parse(await readFile(new URL("vim-token-manifest.json", root), "utf8"));
const classifications = new Set(["supported", "adapted", "unsupported"]);

export function validateVimCompatibility(matrix) {
  if (!matrix || matrix.version !== 1 || !Array.isArray(matrix.commands)) throw new Error("matrix must be version 1 with commands");
  const ids = new Set();
  const counts = { supported: 0, adapted: 0, unsupported: 0 };
  for (const entry of matrix.commands) {
    const keys = Object.keys(entry).sort().join(",");
    const expected = (entry.nativeAction === undefined ? ["classification", "id", "notation", "outcome"] : ["classification", "id", "nativeAction", "notation", "outcome"]).sort().join(",");
    if (keys !== expected) throw new Error(`invalid fields for ${entry.id ?? "unknown"}`);
    if (typeof entry.id !== "string" || ids.has(entry.id)) throw new Error(`duplicate or invalid id: ${entry.id}`);
    if (typeof entry.notation !== "string" || typeof entry.outcome !== "string" || !classifications.has(entry.classification)) throw new Error(`invalid entry: ${entry.id}`);
    if (entry.nativeAction !== undefined && (entry.classification !== "adapted" || !["save", "quit"].includes(entry.nativeAction))) throw new Error(`invalid native action: ${entry.id}`);
    if (entry.classification === "unsupported" && (!entry.outcome.includes("Document unchanged") || !entry.outcome.includes("no native action") && !entry.outcome.includes("no native action") && !entry.outcome.includes("no window action") && !entry.outcome.includes("no mapping") && !entry.outcome.includes("no path"))) throw new Error(`unsafe unsupported outcome: ${entry.id}`);
    ids.add(entry.id); counts[entry.classification] += 1;
  }
  const missing = required.filter(id => !ids.has(id));
  const extra = [...ids].filter(id => !required.includes(id));
  if (missing.length || extra.length) throw new Error(`manifest mismatch; missing=${missing.join("|")} extra=${extra.join("|")}`);
  if (Object.keys(tokenManifest).sort().join("|") !== [...ids].sort().join("|")) throw new Error("token manifest rows do not match matrix rows");
  const tokens = Object.entries(tokenManifest).flatMap(([row, values]) => {
    if (!Array.isArray(values) || values.length === 0 || values.some(value => typeof value !== "string" || !value)) throw new Error(`invalid token manifest row: ${row}`);
    if (new Set(values).size !== values.length) throw new Error(`duplicate token in row: ${row}`);
    return values;
  });
  return { total: ids.size, tokens: tokens.length, ...counts };
}

const escapeCell = value => String(value).replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll("|", "\\|").replaceAll("\n", " ");

export function generateVimCompatibility(matrix) {
  const summary = validateVimCompatibility(matrix);
  const rows = matrix.commands.map(entry => `| <code>${escapeCell(entry.notation)}</code> | ${entry.classification} | ${escapeCell(entry.outcome)} |`);
  return [
    "# Vim compatibility",
    "",
    "FIELDNOTES uses Vim bindings by default. Presentation-mode changes preserve the same editor and Vim adapter; toggling Vim itself resets adapter-local mode state.",
    "",
    `Matrix v${matrix.version}: ${summary.total} command families / ${summary.tokens} executable tokens (${summary.supported} supported, ${summary.adapted} adapted, ${summary.unsupported} unsupported families).`,
    "",
    "| Command | Classification | Exact behavior |",
    "| --- | --- | --- |",
    ...rows,
    "",
    "Unsupported commands never gain filesystem, shell, buffer, or window authority. `:write` and `:quit` are the only Ex commands adapted to native actions, and they run only after pending edits are acknowledged.",
    "",
  ].join("\n");
}

async function main() {
  const matrix = JSON.parse(await readFile(new URL("vim-compatibility.json", root), "utf8"));
  const output = generateVimCompatibility(matrix);
  const destination = new URL("docs/vim-compatibility.md", root);
  if (process.argv.includes("--check")) {
    const current = await readFile(destination, "utf8").catch(() => "");
    if (current !== output) throw new Error("docs/vim-compatibility.md is stale; run npm run generate:vim-docs");
  } else {
    await writeFile(destination, output, "utf8");
  }
}

if (fileURLToPath(import.meta.url) === process.argv[1]) await main();
