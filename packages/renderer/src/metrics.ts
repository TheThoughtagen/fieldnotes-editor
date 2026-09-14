type MarkdownNode = {
  type: string;
  value?: string;
  alt?: string | null;
  children?: unknown[];
};

const excludedTypes = new Set(["code", "inlineCode", "math", "inlineMath"]);
const separatedChildren = new Set(["root", "blockquote", "list", "listItem", "table", "tableRow"]);

export function deriveTextMetrics(tree: unknown, wordsPerMinute: number): {
  plainText: string;
  wordCount: number;
  readingMinutes: number;
} {
  const plainText = normalizeWhitespace(visibleText(tree));
  const wordCount = plainText === "" ? 0 : plainText.split(/\s+/u).length;

  return {
    plainText,
    wordCount,
    readingMinutes: Math.max(1, Math.ceil(wordCount / wordsPerMinute))
  };
}

function visibleText(value: unknown): string {
  if (!isMarkdownNode(value) || excludedTypes.has(value.type)) {
    return "";
  }

  if (value.type === "text") {
    return value.value ?? "";
  }

  if (value.type === "image" || value.type === "imageReference") {
    return value.alt ?? "";
  }

  if (value.type === "break") {
    return " ";
  }

  const separator = separatedChildren.has(value.type) ? " " : "";
  return value.children?.map(visibleText).filter(Boolean).join(separator) ?? "";
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/gu, " ").trim();
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
