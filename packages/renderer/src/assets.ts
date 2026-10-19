import { posix } from "node:path";
import { normalizeUri } from "micromark-util-sanitize-uri";
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
    // CommonMark uses the first definition of a label; later duplicates are ignored.
    if (node.type === "definition" && node.identifier && node.url
      && !definitions.has(node.identifier.toLowerCase())) {
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
      const filePath = target.url.split(/[?#]/u)[0] ?? "";
      asset.resolvedPath = posix.normalize(posix.join(posix.dirname(options.sourcePath), filePath));
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

// Only document-relative paths count. Browsers read "\\" as "/", so "/\\host" or "\\\\host" would reach another origin;
// reject backslashes, whitespace, control characters, schemes, and anything rooted at "/".
export function isLocalVideo(url: string): boolean {
  const path = url.split(/[?#]/u)[0] ?? "";
  return !/[\\\u0000-\u0020\u007f]/u.test(url)
    && !/^[a-z][a-z0-9+.-]*:/iu.test(url)
    && !url.startsWith("/")
    && videoExtension.test(path);
}

function markAsVideo(node: MarkdownNode, url: string, alt: string, title: string | undefined): void {
  const src = normalizeUri(url);
  node.data = {
    ...node.data,
    hName: "video",
    hProperties: {
      ...(alt === "" ? {} : { ariaLabel: alt }),
      controls: true,
      playsInline: true,
      preload: "metadata",
      src,
      ...(title === undefined ? {} : { title })
    },
    // Text fallback: a link here would nest inside [![...](clip.mp4)](url) and break the video.
    hChildren: [{ type: "text", value: alt === "" ? src : alt }]
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
