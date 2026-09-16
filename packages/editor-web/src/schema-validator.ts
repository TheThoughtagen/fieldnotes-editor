// A fixed entry point for native JavaScriptCore. It exposes no native capabilities.
import { extractFrontmatter, validateFrontmatter } from "../../renderer/src/frontmatter.js";
export function validate(source: string, schemaJSON: string): string {
  return JSON.stringify(validateFrontmatter(extractFrontmatter(source).data, JSON.parse(schemaJSON)));
}
