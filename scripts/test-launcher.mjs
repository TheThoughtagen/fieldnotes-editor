import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, copyFileSync, writeFileSync, chmodSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
const root = mkdtempSync(join(tmpdir(), "fieldnotes-launcher-"));
try {
  const app = join(root, "An App.app", "Contents");
  mkdirSync(join(app, "Resources", "bin"), { recursive: true }); mkdirSync(join(app, "MacOS")); mkdirSync(join(root, "bin"));
  const launcher = join(app, "Resources", "bin", "fieldnotes");
  copyFileSync(new URL("fieldnotes-launcher.sh", import.meta.url), launcher); chmodSync(launcher, 0o755);
  const native = join(app, "MacOS", "fieldnotes");
  writeFileSync(native, '#!/bin/sh\nprintf "%s\\n" "$@"\n'); chmodSync(native, 0o755);
  symlinkSync(launcher, join(root, "bin", "first")); symlinkSync("first", join(root, "bin", "fieldnotes"));
  const result = spawnSync(join(root, "bin", "fieldnotes"), ["a file.md", "--help"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, "a file.md\n--help\n");
} finally { rmSync(root, { recursive: true, force: true }); }
