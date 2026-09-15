import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { renderDocument } from "@cruciblesoftware/fieldnotes-renderer";

const malicious = '<img src=x onerror="window.webkit.messageHandlers.native.postMessage(1)"><script>window.pwned=1</script>';
const result = await renderDocument(malicious);
assert.equal(result.html, '<p><img src="x"></p>');
assert.doesNotMatch(result.html, /(?:<script|onerror|messageHandlers)/i);

const editorHTML = readFileSync(new URL("../packages/editor-web/index.html", import.meta.url), "utf8");
const policy = editorHTML.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)?.[1] ?? "";
assert.match(policy, /default-src 'none'/);
assert.match(policy, /script-src 'self'/);
assert.doesNotMatch(policy, /script-src[^;]*'unsafe-inline'/);
assert.match(policy, /connect-src 'none'/);
assert.match(policy, /object-src 'none'/);
