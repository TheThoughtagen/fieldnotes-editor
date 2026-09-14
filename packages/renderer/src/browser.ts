import { canonicalMermaidSource, sha256 } from "./mermaid.js";

export type MermaidRenderer = {
  initialize(config: {
    startOnLoad: boolean;
    securityLevel: "strict";
    theme?: "default" | "dark" | "neutral";
  }): void;
  render(id: string, source: string, container?: HTMLElement): Promise<{ svg: string }>;
};

export type MermaidHydrationOptions = {
  theme?: "default" | "dark" | "neutral";
  renderer?: MermaidRenderer;
};

export type MermaidHydrationResult = {
  hash: string;
  status: "rendered" | "error";
  message?: string;
};

const digestPattern = /^sha256:([a-f0-9]{64})$/u;

export async function hydrateMermaid(
  root: ParentNode,
  options: MermaidHydrationOptions = {}
): Promise<MermaidHydrationResult[]> {
  const renderer = options.renderer ?? (await import("mermaid")).default;
  renderer.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    ...(options.theme === undefined ? {} : { theme: options.theme })
  });
  const placeholders = [...root.querySelectorAll<HTMLPreElement>("pre.fieldnotes-mermaid[data-fieldnotes-mermaid]")];
  const results: MermaidHydrationResult[] = [];
  for (const [index, placeholder] of placeholders.entries()) {
    const source = canonicalMermaidSource(placeholder.textContent ?? "");
    const hash = placeholder.dataset.fieldnotesMermaid ?? "";
    const match = digestPattern.exec(hash);
    if (match === null) {
      results.push(errorResult(placeholder, source, hash, "Mermaid placeholder has an invalid digest."));
      continue;
    }
    if (await sha256(source) !== match[1]) {
      results.push(errorResult(placeholder, source, hash, "Mermaid source digest does not match placeholder."));
      continue;
    }
    try {
      const renderId = `fieldnotes-mermaid-${match[1].slice(0, 16)}-${index}`;
      const { svg } = await renderer.render(renderId, source, placeholder);
      const element = parseAndSanitizeSvg(svg, `${match[1].slice(0, 12)}-${index}`);
      placeholder.replaceWith(element);
      results.push({ hash, status: "rendered" });
    } catch {
      results.push(errorResult(placeholder, source, hash, "Mermaid could not render this diagram."));
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
  hash: string,
  message: string
): MermaidHydrationResult {
  const error = document.createElement("pre");
  error.className = "fieldnotes-mermaid-error";
  error.textContent = source;
  placeholder.replaceWith(error);
  return { hash, status: "error", message };
}

function parseAndSanitizeSvg(source: string, namespace: string): SVGSVGElement {
  const template = document.createElement("template");
  template.innerHTML = source;
  const svg = template.content.querySelector("svg");
  if (!(svg instanceof SVGSVGElement)) throw new TypeError("Mermaid did not return an SVG element.");
  const forbiddenElements = new Set([
    "animate", "animatemotion", "animatetransform", "discard", "foreignobject", "script", "set"
  ]);
  for (const element of [...svg.querySelectorAll("*")]) {
    const tag = element.localName.toLowerCase();
    if (forbiddenElements.has(tag)) element.remove();
  }
  const idMap = new Map<string, string>();
  [svg, ...svg.querySelectorAll<SVGElement>("[id]")].filter(element => element.hasAttribute("id"))
    .forEach((element, index) => {
      const original = element.id;
      const normalized = `fieldnotes-${namespace}-${index}`;
      idMap.set(original, normalized);
      element.id = normalized;
    });
  for (const style of [...svg.querySelectorAll("style")]) {
    if (hasExternalCss(style.textContent ?? "", true)) {
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
    if (hasExternalCss(value)) {
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

function hasExternalCss(value: string, allowKeyframes = false): boolean {
  const remainingAtRules = allowKeyframes ? value.replace(/@keyframes\b/giu, "") : value;
  if (remainingAtRules.includes("@")) return true;
  const urls = [...value.matchAll(/url\(\s*['"]?([^)'"\s]+)['"]?\s*\)/giu)];
  return urls.some(match => !match[1].startsWith("#"));
}

function normalizeElementTree(element: Element): void {
  for (const child of [...element.children]) normalizeElementTree(child);
  const attributes = [...element.attributes]
    .map(attribute => [attribute.name, attribute.value] as const)
    .sort(([left], [right]) => left < right ? -1 : left > right ? 1 : 0);
  for (const attribute of [...element.attributes]) element.removeAttribute(attribute.name);
  for (const [name, value] of attributes) element.setAttribute(name, value);
}
