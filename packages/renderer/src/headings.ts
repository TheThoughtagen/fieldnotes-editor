import GithubSlugger from "github-slugger";
import type { Heading } from "./types.js";

type MarkdownNode = {
  type: string;
  depth?: number;
  value?: string;
  alt?: string | null;
  children?: unknown[];
  data?: { hProperties?: Record<string, unknown> };
};

export function assignHeadingIdsAndBuildToc(tree: unknown): Heading[] {
  const slugger = new GithubSlugger();
  const toc: Heading[] = [];
  let currentRoot: Heading | undefined;

  visitNodes(tree, (node) => {
    if (node.type !== "heading" || node.depth === undefined) {
      return;
    }

    const text = headingText(node);
    const id = slugger.slug(text);
    node.data = {
      ...node.data,
      hProperties: { ...node.data?.hProperties, id }
    };

    if (node.depth === 2) {
      currentRoot = { depth: 2, id, text, children: [] };
      toc.push(currentRoot);
    } else if (node.depth === 3 && currentRoot !== undefined) {
      currentRoot.children.push({ depth: 3, id, text, children: [] });
    }
  });

  return toc;
}

function visitNodes(value: unknown, visitor: (node: MarkdownNode) => void): void {
  if (!isMarkdownNode(value)) {
    return;
  }

  const node = value;
  visitor(node);
  node.children?.forEach((child) => visitNodes(child, visitor));
}

function headingText(value: unknown): string {
  if (!isMarkdownNode(value)) {
    return "";
  }

  const node = value;
  if (node.type === "text" || node.type === "inlineCode" || node.type === "html") {
    return node.value ?? "";
  }

  if (node.type === "image") {
    return node.alt ?? "";
  }

  return node.children?.map(headingText).join("") ?? "";
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
