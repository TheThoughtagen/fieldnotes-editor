import { posix } from "node:path";
import type { AssetReference, RenderDiagnostic } from "./types.js";

type MarkdownNode = {
  type: string;
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
    const asset: AssetReference = {
      kind: "image",
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
