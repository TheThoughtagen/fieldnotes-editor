import type { RenderDiagnostic } from "../types.js";

type Node = {
  type: string;
  lang?: string | null;
  meta?: string | null;
  value?: string;
  children?: unknown[];
  data?: { hProperties?: Record<string, unknown> };
};

type HastNode = {
  type: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

export function prepareCodeHighlightRanges(tree: unknown, diagnostics: RenderDiagnostic[]): void {
  visitMarkdown(tree, node => {
    if (node.type !== "code" || node.lang === "mermaid" || node.meta == null) {
      return;
    }

    const lineCount = node.value === "" || node.value === undefined ? 0 : node.value.split("\n").length;
    const highlighted = parseHighlightRanges(node.meta, lineCount);
    if (highlighted === undefined) {
      diagnostics.push({
        code: "code.highlight-range",
        message: `Invalid code highlight range: ${node.meta}`,
        severity: "warning"
      });
      return;
    }

    node.data = {
      ...node.data,
      hProperties: {
        ...node.data?.hProperties,
        "data-highlight-lines": [...highlighted].sort((left, right) => left - right).join(",")
      }
    };
  });
}

export function transformAdvancedHtml(tree: unknown): void {
  if (!isHastNode(tree)) {
    return;
  }

  visitHast(tree, node => {
    if (node.tagName === "code") {
      wrapHighlightedLines(node);
    }
  });
  transformFigures(tree);
}

function parseHighlightRanges(meta: string, lineCount: number): Set<number> | undefined {
  const match = /^\{([^{}]+)\}$/u.exec(meta.trim());
  if (match === null) {
    return undefined;
  }

  const result = new Set<number>();
  for (const part of match[1].split(",")) {
    const range = /^(\d+)(?:-(\d+))?$/u.exec(part);
    if (range === null) {
      return undefined;
    }
    const start = Number(range[1]);
    const end = Number(range[2] ?? range[1]);
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)
      || start < 1 || end < start || start > lineCount || end > lineCount) {
      return undefined;
    }
    for (let line = start; line <= end; line += 1) {
      result.add(line);
    }
  }
  return result;
}

function wrapHighlightedLines(code: HastNode): void {
  const encoded = code.properties?.dataHighlightLines ?? code.properties?.["data-highlight-lines"];
  if (typeof encoded !== "string") {
    return;
  }

  delete code.properties?.dataHighlightLines;
  delete code.properties?.["data-highlight-lines"];
  const highlighted = new Set(encoded.split(",").map(Number));
  const lines = splitIntoLines(code.children ?? []);
  if (lines.at(-1)?.length === 0) {
    lines.pop();
  }
  code.children = lines.flatMap((children, index) => {
    const line: HastNode = {
      type: "element",
      tagName: "span",
      properties: {
        className: ["code-line"],
        ...(highlighted.has(index + 1) ? { dataHighlightedLine: "true" } : {})
      },
      children
    };
    return index === lines.length - 1 ? [line] : [line, { type: "text", value: "\n" }];
  });
}

function splitIntoLines(nodes: HastNode[]): HastNode[][] {
  const lines: HastNode[][] = [[]];
  for (const node of nodes) {
    if (node.type === "text") {
      const parts = (node.value ?? "").split("\n");
      parts.forEach((part, index) => {
        if (part !== "") {
          lines.at(-1)?.push({ type: "text", value: part });
        }
        if (index < parts.length - 1) {
          lines.push([]);
        }
      });
      continue;
    }

    const childLines = splitIntoLines(node.children ?? []);
    childLines.forEach((children, index) => {
      const clone = { ...node, children };
      if (children.length > 0) {
        lines.at(-1)?.push(clone);
      }
      if (index < childLines.length - 1) {
        lines.push([]);
      }
    });
  }
  return lines;
}

function transformFigures(parent: HastNode): void {
  parent.children?.forEach((child, index) => {
    if (child.tagName === "p" && child.children?.length === 1) {
      const image = child.children[0];
      const title = image.tagName === "img" ? image.properties?.title : undefined;
      if (typeof title === "string" && title.length > 0) {
        parent.children![index] = {
          type: "element",
          tagName: "figure",
          properties: {},
          children: [image, {
            type: "element",
            tagName: "figcaption",
            properties: {},
            children: [{ type: "text", value: title }]
          }]
        };
      }
    }
    transformFigures(parent.children?.[index] ?? child);
  });
}

function visitMarkdown(value: unknown, visitor: (node: Node) => void): void {
  if (!isMarkdownNode(value)) return;
  visitor(value);
  value.children?.forEach(child => visitMarkdown(child, visitor));
}

function visitHast(value: HastNode, visitor: (node: HastNode) => void): void {
  visitor(value);
  value.children?.forEach(child => visitHast(child, visitor));
}

function isMarkdownNode(value: unknown): value is Node {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}

function isHastNode(value: unknown): value is HastNode {
  return isMarkdownNode(value);
}
