import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, mkdtempSync, mkdirSync, copyFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parse } from "yaml";
const root = new URL("../", import.meta.url);
const env = { ...process.env };
for (const name of ["DEVELOPER_ID", "NOTARY_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER", "APP_VERSION"]) delete env[name];
const result = spawnSync("scripts/sign-and-package.sh", [], { cwd: root, env, encoding: "utf8" });
assert.equal(result.status, 1);
assert.match(result.stderr, /Required release credential\/value missing: DEVELOPER_ID/);
const release = parse(readFileSync(new URL(".github/workflows/release-app.yml", root), "utf8"));
assert.deepEqual(release.on.push.tags, ["v*"]);
assert.equal(release.jobs.release.needs, "verify");
const script = readFileSync(new URL("scripts/sign-and-package.sh", root), "utf8");
assert.doesNotMatch(script, /--deep/);
const stapleValidation = script.indexOf('stapler validate');
const checksum = script.indexOf('shasum -a 256');
assert.ok(stapleValidation >= 0, 'staple validation must exist');
assert.ok(checksum >= 0, 'final artifact checksum must exist');
assert.ok(stapleValidation < checksum);
const job = release.jobs.release;
const secretNames = ["DEVELOPER_ID", "SIGNING_CERTIFICATE", "SIGNING_PASSWORD", "NOTARY_PRIVATE_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER", "TAP_TOKEN"];
for (const key of secretNames) assert.equal(job.env[key], undefined, `${key} must not be job-scoped`);
assert.equal(job.steps.find(step => step.uses?.startsWith("actions/checkout@"))?.with?.["persist-credentials"], false);
const byName = name => job.steps.find(step => step.name === name);
assert.deepEqual(Object.keys(byName("Require all release credentials and valid tag").env).sort(), [...secretNames].sort());
assert.deepEqual(Object.keys(byName("Import temporary signing credentials").env).sort(), ["SIGNING_CERTIFICATE", "SIGNING_PASSWORD", "NOTARY_PRIVATE_KEY"].sort());
assert.deepEqual(Object.keys(job.steps.find(step => step.run === "scripts/sign-and-package.sh").env).sort(), ["DEVELOPER_ID", "NOTARY_KEY_ID", "NOTARY_ISSUER"].sort());
assert.ok(byName("Update tap after release exists").env.TAP_TOKEN);
for (const step of job.steps.filter(step => /npm |bundle-app/.test(step.run ?? ""))) {
  assert.equal(step.env, undefined, 'dependency and build steps receive no release credentials');
}
const entitlement = readFileSync(new URL("packaging/Fieldnotes.entitlements", root), "utf8");
assert.doesNotMatch(entitlement, /get-task-allow|disable-library-validation|allow-jit|allow-unsigned-executable-memory/);
const preview = readFileSync(new URL("scripts/package-unsigned-preview.sh", root), "utf8");
for (const value of [undefined, "", "../1.0.0", "1.2", "01.2.3", "1.2.3-preview", "1.2.3\n", "1.2.3;touch /tmp/invalid", "1.2.3\n4.5.6"]) {
  const previewEnv = { ...env };
  if (value !== undefined) previewEnv.APP_VERSION = value;
  const invalid = spawnSync("scripts/package-unsigned-preview.sh", [], { cwd: root, env: previewEnv, encoding: "utf8" });
  assert.equal(invalid.status, 1, `invalid preview version ${JSON.stringify(value)} must fail`);
  assert.match(invalid.stderr, /Invalid or missing APP_VERSION/);
  if (value) {
    const invalidBundle = spawnSync("scripts/bundle-app.sh", ["release"], { cwd: root, env: previewEnv, encoding: "utf8" });
    assert.equal(invalidBundle.status, 1);
    assert.match(invalidBundle.stderr, /Invalid APP_VERSION/);
  }
}
// Exercise version mismatch in an isolated bundle before any signature or DMG tools run.
if (process.platform === "darwin") {
  const sandbox = mkdtempSync(join(tmpdir(), "fieldnotes-preview-contract-"));
  try {
    mkdirSync(join(sandbox, "scripts"));
    mkdirSync(join(sandbox, "build/FIELDNOTES.app/Contents"), { recursive: true });
    copyFileSync(new URL("scripts/package-unsigned-preview.sh", root), join(sandbox, "scripts/package-unsigned-preview.sh"));
    for (const [shortVersion, buildVersion, expectedKey] of [
      ["0.2.0", "0.2.0", "CFBundleShortVersionString"],
      ["0.1.0", "7", "CFBundleVersion"],
    ]) {
      writeFileSync(join(sandbox, "build/FIELDNOTES.app/Contents/Info.plist"), `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>${shortVersion}</string><key>CFBundleVersion</key><string>${buildVersion}</string></dict></plist>`);
      const mismatch = spawnSync("bash", ["scripts/package-unsigned-preview.sh"], { cwd: sandbox, env: { ...env, APP_VERSION: "0.1.0" }, encoding: "utf8" });
      assert.equal(mismatch.status, 1);
      assert.match(mismatch.stderr, new RegExp(`Bundle ${expectedKey} is`));
    }
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}
assert.match(preview, /scripts\/sign-and-package\.sh --verify-unsigned/);
assert.match(preview, /Signature=adhoc/);
assert.doesNotMatch(preview, /PlistBuddy -c "Set|notarytool|--sign/);
assert.ok(preview.indexOf("--verify-unsigned") < preview.indexOf("hdiutil create"));
assert.ok(preview.indexOf("hdiutil verify") < preview.indexOf("shasum -a 256"));
assert.match(preview, /FIELDNOTES-\$APP_VERSION-unsigned-preview-universal/);
assert.match(preview, /ln -s \/Applications/);
assert.match(preview, /not Developer ID signed and is not notarized/);
assert.match(script, /Resources\/AppIcon\.icns/);
const appCI = parse(readFileSync(new URL(".github/workflows/app-ci.yml", root), "utf8"));
const previewStep = appCI.jobs.verify.steps.find(step => step.name === "Package unsigned preview");
assert.match(previewStep.run, /scripts\/package-unsigned-preview\.sh/);
assert.equal(previewStep.env, undefined);
const artifact = appCI.jobs.verify.steps.find(step => step.uses?.startsWith("actions/upload-artifact@"));
assert.equal(artifact.with.name, "FIELDNOTES-unsigned-preview-universal");
assert.match(artifact.with.path, /unsigned-preview-universal\.dmg/);
assert.match(artifact.with.path, /unsigned-preview-universal\.sha256/);
console.log("Release fail-closed, preview version, and artifact-order checks passed");
