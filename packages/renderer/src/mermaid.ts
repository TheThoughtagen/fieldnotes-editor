type HastNode = {
  type: string;
  tagName?: string;
  value?: string;
  properties?: Record<string, unknown>;
  children?: HastNode[];
};

export async function transformMermaidPlaceholders(tree: unknown): Promise<void> {
  if (!isHastNode(tree)) return;
  await Promise.all((tree.children ?? []).map(child => transformMermaidPlaceholders(child)));
  if (tree.tagName !== "pre" || tree.children?.length !== 1) return;
  const code = tree.children[0];
  const classes = Array.isArray(code.properties?.className) ? code.properties.className : [];
  if (code.tagName !== "code" || !classes.includes("language-mermaid")) return;

  const canonical = canonicalMermaidSource(textContent(code));
  tree.properties = {
    className: ["fieldnotes-mermaid"],
    dataFieldnotesMermaid: `sha256:${await sha256(canonical)}`
  };
  tree.children = [{ type: "text", value: canonical }];
}

export function canonicalMermaidSource(source: string): string {
  return source.replace(/\r\n?/gu, "\n").replace(/\n$/u, "");
}

export async function sha256(source: string): Promise<string> {
  const bytes = new TextEncoder().encode(source);
  const digest = await globalThis.crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}

function textContent(node: HastNode): string {
  return node.type === "text"
    ? node.value ?? ""
    : (node.children ?? []).map(textContent).join("");
}

function isHastNode(value: unknown): value is HastNode {
  return typeof value === "object" && value !== null && "type" in value && typeof value.type === "string";
}
