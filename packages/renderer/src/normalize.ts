import rehypeRaw from "rehype-raw";
import rehypeStringify from "rehype-stringify";
import { unified } from "unified";
import type { Root } from "hast";

type HastNode = {
  type: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

export function normalizeHtml(html: string): string {
  const source = html.replace(/\r\n?/gu, "\n");
  const tree = unified().use(rehypeRaw).runSync({
    type: "root",
    children: [{ type: "raw", value: source }]
  });
  return serializeNormalizedHtml(tree);
}

export function serializeNormalizedHtml(tree: unknown): string {
  if (!isHastNode(tree) || tree.type !== "root") {
    throw new TypeError("Expected a HAST root node.");
  }
  normalizeText(tree);
  sortAttributes(tree);
  return String(unified().use(rehypeStringify).stringify(tree as Root));
}

function normalizeText(value: unknown): void {
  if (!isHastNode(value)) {
    return;
  }
  if (typeof value.value === "string") {
    value.value = value.value.replace(/\r\n?/gu, "\n");
  }
  value.children?.forEach(normalizeText);
}

function sortAttributes(value: unknown): void {
  if (!isHastNode(value)) {
    return;
  }
  if (value.properties !== undefined) {
    value.properties = Object.fromEntries(
      Object.entries(value.properties).sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0)
    );
  }
  value.children?.forEach(sortAttributes);
}

function isHastNode(value: unknown): value is HastNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
