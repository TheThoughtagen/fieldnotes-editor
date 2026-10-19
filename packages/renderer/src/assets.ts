import { posix } from "node:path";
import type { AssetReference, RenderDiagnostic } from "./types.js";

type MarkdownNode = {
  type: string;
  data?: { hName?: string; hProperties?: Record<string, unknown>; hChildren?: unknown[] };
  url?: string;
  title?: string | null;
  alt?: string | null;
  identifier?: string;
  children?: unknown[];
};

type AssetDiscovery = {
  assets: AssetReference[];
  diagnostics: RenderDiagnostic[];
};

export function discoverImageAssets(
  tree: unknown,
  options: { sourcePath?: string; allowRemoteImages?: boolean }
): AssetDiscovery {
  const definitions = new Map<string, { url: string; title?: string }>();
  visitNodes(tree, node => {
    if (node.type === "definition" && node.identifier && node.url) {
      definitions.set(node.identifier.toLowerCase(), {
        url: node.url,
        ...(node.title == null ? {} : { title: node.title })
      });
    }
  });

  const assets: AssetReference[] = [];
  const diagnostics: RenderDiagnostic[] = [];
  visitNodes(tree, node => {
    const target = node.type === "image"
      ? node.url ? { url: node.url, title: node.title ?? undefined } : undefined
      : node.type === "imageReference" && node.identifier
        ? definitions.get(node.identifier.toLowerCase())
        : undefined;
    if (!target) {
      return;
    }

    const remote = /^https?:/iu.test(target.url);
    const video = isLocalVideo(target.url);
    if (video) {
      markAsVideo(node, target.url, node.alt ?? "", target.title);
    }
    const asset: AssetReference = {
      kind: video ? "video" : "image",
      source: target.url,
      remote,
      alt: node.alt ?? "",
      ...(target.title === undefined ? {} : { title: target.title })
    };
    if (!remote && options.sourcePath !== undefined) {
      asset.resolvedPath = posix.normalize(posix.join(posix.dirname(options.sourcePath), target.url));
    }
    assets.push(asset);

    if (remote && options.allowRemoteImages === false) {
      diagnostics.push({
        code: "image.remote-disabled",
        message: `Remote image is disabled: ${target.url}`,
        severity: "warning"
      });
    }
  });

  return { assets, diagnostics };
}

const videoExtension = /\.(?:mp4|webm)$/iu;

// Only relative paths count: no scheme, no protocol-relative host, so the document's own folder holds the file.
export function isLocalVideo(url: string): boolean {
  const path = url.split(/[?#]/u)[0] ?? "";
  return !/^[a-z][a-z0-9+.-]*:/iu.test(url) && !url.startsWith("//") && videoExtension.test(path);
}

function markAsVideo(node: MarkdownNode, url: string, alt: string, title: string | undefined): void {
  node.data = {
    ...node.data,
    hName: "video",
    hProperties: {
      ...(alt === "" ? {} : { ariaLabel: alt }),
      controls: true,
      playsInline: true,
      preload: "metadata",
      src: url,
      ...(title === undefined ? {} : { title })
    },
    hChildren: [{
      type: "element",
      tagName: "a",
      properties: { href: url },
      children: [{ type: "text", value: alt === "" ? url : alt }]
    }]
  };
}

function visitNodes(value: unknown, visitor: (node: MarkdownNode) => void): void {
  if (!isMarkdownNode(value)) {
    return;
  }
  visitor(value);
  value.children?.forEach(child => visitNodes(child, visitor));
}

function isMarkdownNode(value: unknown): value is MarkdownNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
