import { build } from "esbuild";
import { fileURLToPath } from "node:url";
const root = new URL("../", import.meta.url);
await build({ entryPoints: [fileURLToPath(new URL("packages/editor-web/src/schema-validator.ts", root))], outfile: fileURLToPath(new URL("build/editor-web/schema-validator.js", root)), bundle: true, platform: "browser", format: "iife", globalName: "FieldnotesValidation", target: "safari17" });
