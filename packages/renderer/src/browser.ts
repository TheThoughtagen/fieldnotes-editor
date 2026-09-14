import mermaid from "mermaid";
import { canonicalMermaidSource, sha256 } from "./mermaid.js";

export type MermaidRenderer = {
  initialize(config: { startOnLoad: boolean; securityLevel: "strict" }): void;
  render(id: string, source: string, container?: HTMLElement): Promise<{ svg: string }>;
};

export type MermaidHydrationOptions = { renderer?: MermaidRenderer };

export type MermaidHydrationResult =
  | { status: "rendered"; digest: string; element: SVGSVGElement }
  | { status: "error"; code: "invalid-digest" | "digest-mismatch" | "render-failed"; element: HTMLPreElement };

const digestPattern = /^sha256:([a-f0-9]{64})$/u;

export async function hydrateMermaid(
  root: ParentNode,
  options: MermaidHydrationOptions = {}
): Promise<MermaidHydrationResult[]> {
  const renderer = options.renderer ?? mermaid;
  renderer.initialize({ startOnLoad: false, securityLevel: "strict" });
  const placeholders = [...root.querySelectorAll<HTMLPreElement>("pre.fieldnotes-mermaid[data-fieldnotes-mermaid]")];
  const results: MermaidHydrationResult[] = [];
  for (const [index, placeholder] of placeholders.entries()) {
    const source = canonicalMermaidSource(placeholder.textContent ?? "");
    const match = digestPattern.exec(placeholder.dataset.fieldnotesMermaid ?? "");
    if (match === null) {
      results.push(errorResult(placeholder, source, "invalid-digest"));
      continue;
    }
    if (await sha256(source) !== match[1]) {
      results.push(errorResult(placeholder, source, "digest-mismatch"));
      continue;
    }
    try {
      const renderId = `fieldnotes-mermaid-${match[1].slice(0, 16)}-${index}`;
      const { svg } = await renderer.render(renderId, source, placeholder);
      const element = parseAndSanitizeSvg(svg, match[1]);
      placeholder.replaceWith(element);
      results.push({ status: "rendered", digest: `sha256:${match[1]}`, element });
    } catch {
      results.push(errorResult(placeholder, source, "render-failed"));
    }
  }
  return results;
}

export function normalizeRenderedDom(root: ParentNode): string {
  const clone = root.cloneNode(true);
  if (clone instanceof Document) {
    normalizeElementTree(clone.documentElement);
    return clone.documentElement.outerHTML;
  }
  if (clone instanceof Element) {
    normalizeElementTree(clone);
    return clone.outerHTML;
  }
  const wrapper = document.createElement("div");
  wrapper.append(clone);
  normalizeElementTree(wrapper);
  return wrapper.innerHTML;
}

function errorResult(
  placeholder: HTMLPreElement,
  source: string,
  code: Extract<MermaidHydrationResult, { status: "error" }>["code"]
): MermaidHydrationResult {
  const error = document.createElement("pre");
  error.className = "fieldnotes-mermaid-error";
  error.textContent = source;
  placeholder.replaceWith(error);
  return { status: "error", code, element: error };
}

function parseAndSanitizeSvg(source: string, digest: string): SVGSVGElement {
  const template = document.createElement("template");
  template.innerHTML = source;
  const svg = template.content.querySelector("svg");
  if (!(svg instanceof SVGSVGElement)) throw new TypeError("Mermaid did not return an SVG element.");
  for (const element of [...svg.querySelectorAll("*")]) {
    const tag = element.localName.toLowerCase();
    if (tag === "script" || tag === "foreignobject") element.remove();
  }
  const idMap = new Map<string, string>();
  [svg, ...svg.querySelectorAll<SVGElement>("[id]")].filter(element => element.hasAttribute("id"))
    .forEach((element, index) => {
    const original = element.id;
    const normalized = `fieldnotes-${digest.slice(0, 12)}-${index}`;
    idMap.set(original, normalized);
    element.id = normalized;
    });
  for (const style of [...svg.querySelectorAll("style")]) {
    if (hasExternalUrl(style.textContent ?? "")) {
      style.remove();
      continue;
    }
    let css = style.textContent ?? "";
    for (const [original, normalized] of idMap) {
      css = css.replaceAll(`#${original}`, `#${normalized}`);
    }
    style.textContent = css;
  }
  sanitizeElement(svg, idMap);
  normalizeElementTree(svg);
  return svg;
}

function sanitizeElement(element: Element, idMap: Map<string, string>): void {
  for (const attribute of [...element.attributes]) {
    const name = attribute.name.toLowerCase();
    const value = attribute.value;
    if (name.startsWith("on")) {
      element.removeAttribute(attribute.name);
      continue;
    }
    if ((name === "href" || name === "xlink:href") && !value.startsWith("#")) {
      element.removeAttribute(attribute.name);
      continue;
    }
    if (hasExternalUrl(value)) {
      element.removeAttribute(attribute.name);
      continue;
    }
    let rewritten = value.replace(/url\(\s*(['"]?)#([^)'"\s]+)\1\s*\)/giu, (_all, _quote, id: string) =>
      `url(#${idMap.get(id) ?? id})`
    );
    if ((name === "href" || name === "xlink:href") && rewritten.startsWith("#")) {
      rewritten = `#${idMap.get(rewritten.slice(1)) ?? rewritten.slice(1)}`;
    } else if (name === "aria-labelledby" || name === "aria-describedby") {
      rewritten = rewritten.split(/\s+/u).map(id => idMap.get(id) ?? id).join(" ");
    }
    if (rewritten !== value) element.setAttribute(attribute.name, rewritten);
  }
  [...element.children].forEach(child => sanitizeElement(child, idMap));
}

function hasExternalUrl(value: string): boolean {
  const urls = [...value.matchAll(/url\(\s*['"]?([^)'"\s]+)['"]?\s*\)/giu)];
  return urls.some(match => !match[1].startsWith("#"));
}

function normalizeElementTree(element: Element): void {
  for (const child of [...element.children]) normalizeElementTree(child);
  const attributes = [...element.attributes]
    .map(attribute => [attribute.name, attribute.value] as const)
    .sort(([left], [right]) => left.localeCompare(right));
  for (const attribute of [...element.attributes]) element.removeAttribute(attribute.name);
  for (const [name, value] of attributes) element.setAttribute(name, value);
}
