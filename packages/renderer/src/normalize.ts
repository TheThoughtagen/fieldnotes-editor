import rehypeRaw from "rehype-raw";
import rehypeStringify from "rehype-stringify";
import { unified } from "unified";
import type { Root } from "hast";

const stringifier = unified().use(rehypeStringify);
const serializedNames = new Map<string, string>();

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
  return String(stringifier.stringify(tree as Root));
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
      Object.entries(value.properties).sort((left, right) => {
        const leftName = serializedAttributeName(left[0], left[1]);
        const rightName = serializedAttributeName(right[0], right[1]);
        return leftName < rightName ? -1 : leftName > rightName ? 1 : 0;
      })
    );
  }
  value.children?.forEach(sortAttributes);
}

function serializedAttributeName(property: string, value: unknown): string {
  const cached = serializedNames.get(property);
  if (cached !== undefined) {
    return cached;
  }
  for (const probe of [value, true, "value"]) {
    const html = String(stringifier.stringify({
      type: "root",
      children: [{ type: "element", tagName: "i", properties: { [property]: probe }, children: [] }]
    } as Root));
    const match = /^<i\s+([^\s=>]+)/u.exec(html);
    if (match !== null) {
      serializedNames.set(property, match[1]);
      return match[1];
    }
  }
  serializedNames.set(property, property);
  return property;
}

function isHastNode(value: unknown): value is HastNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
