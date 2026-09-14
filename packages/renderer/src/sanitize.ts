import { defaultSchema } from "rehype-sanitize";
import type { Options as SanitizeSchema } from "rehype-sanitize";
import type { RenderDiagnostic } from "./types.js";

type HastNode = {
  type: string;
  tagName?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
  position?: { start?: { offset?: number }; end?: { offset?: number } };
};

type MarkdownNode = HastNode & {
  depth?: number;
  data?: { hProperties?: Record<string, unknown> };
  value?: string;
};

export type TrustedMarkup = {
  ids: Map<string, string>;
  highlightLines: Map<string, string>;
  footnoteReferences: Map<string, Record<string, unknown>>;
  footnoteSection?: {
    labelId?: string;
    definitionIds: string[];
    backreferenceHrefs: string[];
  };
};

const iframeHosts = new Map([
  ["www.youtube-nocookie.com", /^\/embed\/[^/]+$/u],
  ["player.vimeo.com", /^\/video\/[0-9]+$/u]
]);

export const sanitizeSchema: SanitizeSchema = {
  ...defaultSchema,
  tagNames: [...(defaultSchema.tagNames ?? []).filter(tag => tag !== "source"), "iframe"],
  attributes: {
    ...defaultSchema.attributes,
    iframe: ["src", "title", "width", "height", "allowFullScreen", "sandbox"]
  },
  protocols: {
    ...defaultSchema.protocols,
    href: ["http", "https", "mailto"],
    src: ["http", "https"]
  }
};

const safeExplicitId = /^[A-Za-z][A-Za-z0-9._:-]*$/u;
const explicitAnchor = /^<a\s+id=(['"])([^'"]+)\1\s*><\/a>\s*$/iu;

export function collectTrustedMarkup(tree: unknown): TrustedMarkup {
  const trusted: TrustedMarkup = {
    ids: new Map(),
    highlightLines: new Map(),
    footnoteReferences: new Map()
  };
  collectMarkdown(tree, trusted);
  return trusted;
}

export function collectTrustedRenderedMarkup(tree: unknown, trusted: TrustedMarkup): void {
  visitNodes(tree, node => {
    if (node.tagName === "a" && node.properties?.dataFootnoteRef !== undefined) {
      trusted.footnoteReferences.set(positionKey("a", node), {
        ariaDescribedBy: node.properties.ariaDescribedBy,
        href: node.properties.href,
        id: node.properties.id
      });
    }
    if (node.tagName === "section" && node.properties?.dataFootnotes !== undefined
      && node.position === undefined) {
      const definitionIds: string[] = [];
      const backreferenceHrefs: string[] = [];
      let labelId: string | undefined;
      visitNodes(node, descendant => {
        if (descendant.tagName === "h2" && typeof descendant.properties?.id === "string") {
          labelId = descendant.properties.id;
        } else if (descendant.tagName === "li" && typeof descendant.properties?.id === "string") {
          definitionIds.push(descendant.properties.id);
        } else if (descendant.tagName === "a" && descendant.properties?.dataFootnoteBackref !== undefined
          && typeof descendant.properties.href === "string") {
          backreferenceHrefs.push(descendant.properties.href);
        }
      });
      trusted.footnoteSection = { labelId, definitionIds, backreferenceHrefs };
    }
  });
}

export function restoreTrustedMarkup(tree: unknown, trusted: TrustedMarkup): void {
  visitNodes(tree, node => {
    if (node.tagName === undefined) {
      return;
    }
    const key = positionKey(node.tagName, node);
    const id = trusted.ids.get(key);
    const highlightLines = trusted.highlightLines.get(key);
    const footnoteReference = trusted.footnoteReferences.get(key);
    if (id !== undefined) {
      node.properties = { ...node.properties, id };
    }
    if (highlightLines !== undefined) {
      node.properties = { ...node.properties, dataHighlightLines: highlightLines };
    }
    if (footnoteReference !== undefined) {
      node.properties = { ...node.properties, ...footnoteReference };
    }
  });
  restoreFootnoteSection(tree, trusted.footnoteSection);
}

function restoreFootnoteSection(
  tree: unknown,
  trusted: TrustedMarkup["footnoteSection"]
): void {
  if (trusted === undefined) {
    return;
  }
  visitNodes(tree, node => {
    if (node.tagName !== "section" || node.properties?.dataFootnotes === undefined
      || node.position !== undefined) {
      return;
    }
    let definitionIndex = 0;
    let backreferenceIndex = 0;
    visitNodes(node, descendant => {
      if (descendant.tagName === "h2" && trusted.labelId !== undefined) {
        descendant.properties = { ...descendant.properties, id: trusted.labelId };
      } else if (descendant.tagName === "li" && definitionIndex < trusted.definitionIds.length) {
        descendant.properties = { ...descendant.properties, id: trusted.definitionIds[definitionIndex++] };
      } else if (descendant.tagName === "a" && descendant.properties?.dataFootnoteBackref !== undefined
        && backreferenceIndex < trusted.backreferenceHrefs.length) {
        descendant.properties = {
          ...descendant.properties,
          href: trusted.backreferenceHrefs[backreferenceIndex++]
        };
      }
    });
  });
}

function collectMarkdown(value: unknown, trusted: TrustedMarkup): void {
  if (!isMarkdownNode(value)) {
    return;
  }
  if (value.type === "heading" && value.depth !== undefined) {
    const id = value.data?.hProperties?.id;
    if (typeof id === "string") {
      trusted.ids.set(positionKey(`h${value.depth}`, value), id);
    }
  }
  if (value.type === "code") {
    const highlightLines = value.data?.hProperties?.dataHighlightLines
      ?? value.data?.hProperties?.["data-highlight-lines"];
    if (typeof highlightLines === "string") {
      trusted.highlightLines.set(positionKey("code", value), highlightLines);
    }
  }
  const children = value.children?.filter(isMarkdownNode) ?? [];
  for (let index = 1; index < children.length; index += 1) {
    const anchor = children[index - 1];
    const heading = children[index];
    const source = anchorSource(anchor);
    const match = source === undefined ? null : explicitAnchor.exec(source);
    const id = match?.[2];
    if (heading.type === "heading" && id !== undefined && safeExplicitId.test(id)
      && heading.data?.hProperties?.id === id) {
      trusted.ids.set(positionKey("a", anchor), id);
    }
  }
  children.forEach(child => collectMarkdown(child, trusted));
}

function anchorSource(node: MarkdownNode): string | undefined {
  if (node.type === "html") {
    return node.value ?? "";
  }
  if (node.type !== "paragraph") {
    return undefined;
  }
  const children = node.children?.filter(isMarkdownNode) ?? [];
  return children.length > 0 && children.every(child => child.type === "html")
    ? children.map(child => child.value ?? "").join("")
    : undefined;
}

function positionKey(tagName: string, node: HastNode): string {
  return `${tagName}:${node.position?.start?.offset ?? -1}:${node.position?.end?.offset ?? -1}`;
}

export function allowedIframe(src: string): boolean {
  try {
    const url = new URL(src);
    const path = iframeHosts.get(url.hostname);
    return url.protocol === "https:"
      && url.username === ""
      && url.password === ""
      && (url.port === "" || url.port === "443")
      && path?.test(url.pathname) === true;
  } catch {
    return false;
  }
}

export function enforceIframePolicy(tree: unknown, diagnostics: RenderDiagnostic[]): void {
  if (!isHastNode(tree)) {
    return;
  }
  filterChildren(tree, diagnostics);
}

function filterChildren(parent: HastNode, diagnostics: RenderDiagnostic[]): void {
  parent.children = parent.children?.filter(child => {
    if (child.tagName !== "iframe") {
      filterChildren(child, diagnostics);
      return true;
    }

    const src = typeof child.properties?.src === "string" ? child.properties.src : "";
    if (!allowedIframe(src)) {
      diagnostics.push({
        code: "iframe.invalid-source",
        message: `Iframe source is not allowed: ${src}`,
        severity: "warning"
      });
      return false;
    }

    const properties = child.properties ?? {};
    const width = integerDimension(properties.width);
    const height = integerDimension(properties.height);
    child.properties = {
      ...(Object.hasOwn(properties, "allowFullScreen") ? { allowFullScreen: true } : {}),
      ...(height === undefined ? {} : { height }),
      sandbox: ["allow-scripts", "allow-same-origin", "allow-presentation"],
      src,
      ...(typeof properties.title === "string" ? { title: properties.title } : {}),
      ...(width === undefined ? {} : { width })
    };
    child.children = [];
    return true;
  });
}

function integerDimension(value: unknown): number | undefined {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value > 0 ? value : undefined;
  }
  if (typeof value === "string" && /^[0-9]+$/u.test(value)) {
    const number = Number(value);
    return Number.isSafeInteger(number) && number > 0 ? number : undefined;
  }
  return undefined;
}

function visitNodes(value: unknown, visitor: (node: HastNode) => void): void {
  if (!isHastNode(value)) {
    return;
  }
  visitor(value);
  value.children?.forEach(child => visitNodes(child, visitor));
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return isHastNode(value);
}

function isHastNode(value: unknown): value is HastNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
