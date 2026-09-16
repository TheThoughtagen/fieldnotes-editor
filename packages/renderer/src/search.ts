import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { isScalar, isSeq, parseDocument } from "yaml";
import { extractFrontmatter } from "./frontmatter.js";

export interface DocumentSearchEntry { title: string; line: number; kind: "heading" | "link" | "tag" }
interface Node {
  type: string; depth?: number; value?: string; alt?: string; identifier?: string;
  children?: Node[]; position?: { start: { line: number } };
}
const text = (node: Node): string => node.type === "html" ? "" : node.value ?? node.alt ?? node.children?.map(text).join("") ?? "";

/** Search labels and destinations share the renderer's Markdown/YAML parse rules. */
export function documentSearchEntries(source: string): DocumentSearchEntry[] {
  const frontmatter = extractFrontmatter(source);
  const bodyOffset = frontmatter.range?.to ?? 0;
  const lineOffset = source.slice(0, bodyOffset).split("\n").length - 1;
  const tree = unified().use(remarkParse).use(remarkGfm).use(remarkMath).parse(frontmatter.body) as Node;
  const entries: DocumentSearchEntry[] = [];
  const definitions = new Set<string>();
  const visit = (node: Node, fn: (node: Node) => void) => { fn(node); node.children?.forEach(child => visit(child, fn)); };
  visit(tree, node => { if (node.type === "definition" && node.identifier) definitions.add(node.identifier); });
  visit(tree, node => {
    const kind = node.type === "heading" && (node.depth === 2 || node.depth === 3) ? "heading"
      : node.type === "link" || (node.type === "linkReference" && definitions.has(node.identifier ?? "")) ? "link" : undefined;
    if (kind && node.position) entries.push({ kind, title: text(node), line: node.position.start.line + lineOffset });
  });
  if (frontmatter.range && frontmatter.diagnostics.length === 0) {
    const yamlStart = source.indexOf("\n") + 1;
    const yaml = source.slice(yamlStart, bodyOffset).replace(/---[\t ]*(?:\r?\n)?$/u, "");
    const tags = parseDocument(yaml, { schema: "core", version: "1.2" }).get("tags", true);
    if (isSeq(tags)) for (const tag of tags.items) {
      if (isScalar(tag) && typeof tag.value === "string" && tag.range) {
        entries.push({ kind: "tag", title: tag.value, line: source.slice(0, yamlStart + tag.range[0]).split("\n").length });
      }
    }
  }
  return entries.sort((a, b) => a.line - b.line);
}
