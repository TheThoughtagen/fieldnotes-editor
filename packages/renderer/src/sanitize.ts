import { defaultSchema } from "rehype-sanitize";
import type { Options as SanitizeSchema } from "rehype-sanitize";
import type { RenderDiagnostic } from "./types.js";

type HastNode = {
  type: string;
  tagName?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

const iframeHosts = new Map([
  ["www.youtube-nocookie.com", /^\/embed\/[^/]+$/u],
  ["player.vimeo.com", /^\/video\/[0-9]+$/u]
]);

export const sanitizeSchema: SanitizeSchema = {
  ...defaultSchema,
  clobber: [],
  tagNames: [...(defaultSchema.tagNames ?? []), "iframe"],
  attributes: {
    ...defaultSchema.attributes,
    code: [...(defaultSchema.attributes?.code ?? []), "dataHighlightLines"],
    iframe: ["src", "title", "width", "height", "allowFullScreen", "sandbox"]
  },
  protocols: {
    ...defaultSchema.protocols,
    href: ["http", "https", "mailto"],
    src: ["http", "https"]
  }
};

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
    return Number.isSafeInteger(value) ? value : undefined;
  }
  if (typeof value === "string" && /^-?[0-9]+$/u.test(value)) {
    const number = Number(value);
    return Number.isSafeInteger(number) ? number : undefined;
  }
  return undefined;
}

function isHastNode(value: unknown): value is HastNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
