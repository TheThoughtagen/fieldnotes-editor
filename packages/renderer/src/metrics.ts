import rehypeRaw from "rehype-raw";
import { unified } from "unified";

type MarkdownNode = {
  type: string;
  value?: string;
  alt?: string | null;
  children?: unknown[];
};

const excludedTypes = new Set(["code", "inlineCode", "math", "inlineMath"]);
const separatedChildren = new Set(["root", "blockquote", "list", "listItem", "table", "tableRow"]);
const excludedHtmlElements = new Set([
  "base", "code", "head", "link", "meta", "noscript", "pre", "script", "source", "style", "template", "title", "track"
]);
const blockHtmlElements = new Set([
  "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
  "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p", "section", "table",
  "tbody", "td", "tfoot", "th", "thead", "tr", "ul"
]);
const rawHtmlParser = unified().use(rehypeRaw);

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

  if (value.type === "html") {
    return visibleHtmlText(value.value ?? "");
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

function visibleHtmlText(value: string): string {
  const tree = rawHtmlParser.runSync({
    type: "root",
    children: [{ type: "raw", value }]
  });
  return visibleHtmlNodeText(tree);
}

function visibleHtmlNodeText(value: unknown): string {
  if (!isHtmlNode(value)) {
    return "";
  }

  if (value.type === "text") {
    return value.value ?? "";
  }

  if (value.type !== "element") {
    return value.children?.map(visibleHtmlNodeText).join("") ?? "";
  }

  const tagName = value.tagName ?? "";
  if (excludedHtmlElements.has(tagName)) {
    return "";
  }

  if (tagName === "br") {
    return " ";
  }

  if (tagName === "img") {
    const alt = value.properties?.alt;
    return typeof alt === "string" ? ` ${alt} ` : "";
  }

  const text = value.children?.map(visibleHtmlNodeText).join("") ?? "";
  return blockHtmlElements.has(tagName) ? `${text} ` : text;
}

function normalizeWhitespace(value: string): string {
  return value.replace(/\s+/gu, " ").trim();
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}

type HtmlNode = {
  type: string;
  value?: string;
  tagName?: string;
  properties?: { alt?: unknown };
  children?: unknown[];
};

function isHtmlNode(value: unknown): value is HtmlNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
