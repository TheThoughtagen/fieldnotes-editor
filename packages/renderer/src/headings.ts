import GithubSlugger from "github-slugger";
import type { Heading, RenderDiagnostic } from "./types.js";

type MarkdownNode = {
  type: string;
  depth?: number;
  value?: string;
  alt?: string | null;
  children?: unknown[];
  data?: { hProperties?: Record<string, unknown> };
};

const safeExplicitId = /^[A-Za-z][A-Za-z0-9._:-]*$/u;
const explicitAnchor = /^<a\s+id=(['"])([^'"]+)\1\s*><\/a>\s*$/iu;

export function assignHeadingIdsAndBuildToc(
  tree: unknown,
  diagnostics: RenderDiagnostic[] = []
): Heading[] {
  const slugger = new GithubSlugger();
  const toc: Heading[] = [];
  const explicitIds = new WeakMap<object, string>();
  const reservedIds = new Set<string>();
  let currentRoot: Heading | undefined;

  collectExplicitAnchors(tree, explicitIds, reservedIds, diagnostics);

  visitNodes(tree, (node) => {
    if (node.type !== "heading" || node.depth === undefined) {
      return;
    }

    const text = headingText(node);
    let id = explicitIds.get(node);
    if (id === undefined) {
      do {
        id = slugger.slug(text);
      } while (reservedIds.has(id));
      reservedIds.add(id);
    }
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

function collectExplicitAnchors(
  value: unknown,
  explicitIds: WeakMap<object, string>,
  reservedIds: Set<string>,
  diagnostics: RenderDiagnostic[]
): void {
  if (!isMarkdownNode(value) || value.children === undefined) {
    return;
  }

  const children = value.children.filter(isMarkdownNode);
  value.children = children;
  for (let index = 1; index < children.length; index += 1) {
    const heading = children[index];
    const candidate = children[index - 1];
    const candidateSource = anchorSource(candidate);
    if (heading.type !== "heading" || candidateSource === undefined || !/^<a\b/iu.test(candidateSource)) {
      continue;
    }

    const match = explicitAnchor.exec(candidateSource);
    const id = match?.[2];
    if (id === undefined || !safeExplicitId.test(id)) {
      diagnostics.push({
        code: "heading.invalid-explicit-id",
        message: `Invalid explicit heading anchor: ${candidateSource}`,
        severity: "warning"
      });
      children.splice(index - 1, 1);
      index -= 1;
      continue;
    }

    if (reservedIds.has(id)) {
      diagnostics.push({
        code: "heading.duplicate-id",
        message: `Duplicate explicit heading anchor: ${id}`,
        severity: "warning"
      });
      children.splice(index - 1, 1);
      index -= 1;
      continue;
    }

    reservedIds.add(id);
    explicitIds.set(heading, id);
  }

  children.forEach(child => collectExplicitAnchors(child, explicitIds, reservedIds, diagnostics));
}

function anchorSource(node: MarkdownNode): string | undefined {
  if (node.type === "html") {
    return node.value ?? "";
  }
  if (node.type !== "paragraph" || node.children === undefined) {
    return undefined;
  }
  const children = node.children.filter(isMarkdownNode);
  if (children.length === 0 || children.some(child => child.type !== "html")) {
    return undefined;
  }
  return children.map(child => child.value ?? "").join("");
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
  if (node.type === "text" || node.type === "inlineCode") {
    return node.value ?? "";
  }

  if (node.type === "html") {
    return (node.value ?? "").replace(/<[^>]*>/gu, "");
  }

  if (node.type === "image") {
    return node.alt ?? "";
  }

  return node.children?.map(headingText).join("") ?? "";
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
