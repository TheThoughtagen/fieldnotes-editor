import { Extension, RangeSetBuilder } from "@codemirror/state";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import type { ImageImportRequest, ImageImportResult } from "./bridge.js";

export interface ImagePolicy {
  generation: number;
  allowRemoteImages: boolean;
}

interface MarkdownImage {
  from: number;
  to: number;
  alt: string;
  path: string;
}

const imagePattern = /!\[([^\]\n]*)\]\(([^)\n]+)\)/gu;

export function resourceURL(path: string, generation: number): string | null {
  const value = path.trim();
  if (!value || value.startsWith("/") || value.startsWith("\\") || value.includes("\\") || /^[a-z][a-z0-9+.-]*:/iu.test(value)) return null;
  const parts = value.split("/");
  if (parts.some(part => !part || part === ".")) return null;
  const encoded = parts.map(part => encodeURIComponent(part)).join("/");
  return generation > 0 ? `fieldnotes-resource://${generation}/resource?path=${encodeURIComponent(value)}` : encoded;
}

export function rewritePreviewImages(root: ParentNode, policy: ImagePolicy): void {
  for (const image of root.querySelectorAll<HTMLImageElement>("img[src]")) {
    const raw = image.getAttribute("src") ?? "";
    if (raw.startsWith("data:")) continue;
    if (/^https:\/\//iu.test(raw)) {
      if (!policy.allowRemoteImages) image.removeAttribute("src");
      continue;
    }
    const local = resourceURL(raw, policy.generation);
    if (local) image.setAttribute("src", local);
    else image.removeAttribute("src");
  }
}

function imagesIn(text: string, offset = 0): MarkdownImage[] {
  const images: MarkdownImage[] = [];
  imagePattern.lastIndex = 0;
  for (let match = imagePattern.exec(text); match; match = imagePattern.exec(text)) {
    images.push({ from: offset + match.index, to: offset + match.index + match[0].length, alt: match[1]!, path: match[2]!.trim() });
  }
  return images;
}

class ImageWidget extends WidgetType {
  constructor(readonly image: MarkdownImage, readonly generation: () => number) { super(); }

  eq(other: ImageWidget): boolean {
    return this.image.from === other.image.from && this.image.to === other.image.to && this.image.alt === other.image.alt && this.image.path === other.image.path && this.generation() === other.generation();
  }

  toDOM(view: EditorView): HTMLElement {
    const wrapper = document.createElement("span");
    wrapper.className = "fn-image-widget fn-image-loading";
    wrapper.setAttribute("role", "button");
    wrapper.setAttribute("tabindex", "0");
    wrapper.setAttribute("aria-label", `${this.image.alt || "Image"}: ${this.image.path}`);
    const image = document.createElement("img");
    image.alt = this.image.alt;
    const source = resourceURL(this.image.path, this.generation());
    if (source) image.src = source;
    const label = document.createElement("span");
    label.className = "fn-image-label";
    label.textContent = `${this.image.alt || "Image"} — ${this.image.path}`;
    wrapper.append(image, label);
    image.addEventListener("load", () => wrapper.classList.remove("fn-image-loading"));
    image.addEventListener("error", () => { wrapper.classList.remove("fn-image-loading"); wrapper.classList.add("fn-image-error"); });
    const select = () => {
      view.dispatch({ selection: { anchor: this.image.from, head: this.image.to }, scrollIntoView: true });
      view.focus();
    };
    wrapper.addEventListener("click", select);
    wrapper.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); select(); } });
    return wrapper;
  }

  ignoreEvent(): boolean { return false; }
}

function decorations(view: EditorView, generation: () => number): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>();
  const selection = view.state.selection.main;
  for (const visible of view.visibleRanges) {
    for (const image of imagesIn(view.state.sliceDoc(visible.from, visible.to), visible.from)) {
      const selected = selection.from <= image.to && selection.to >= image.from && (selection.from !== selection.to || (selection.head >= image.from && selection.head <= image.to));
      if (!selected) builder.add(image.from, image.to, Decoration.replace({ widget: new ImageWidget(image, generation) }));
    }
  }
  return builder.finish();
}

export function focusImages(generation: () => number = () => 0): Extension {
  return ViewPlugin.fromClass(class {
    decorations: DecorationSet;
    constructor(view: EditorView) { this.decorations = decorations(view, generation); }
    update(update: ViewUpdate) {
      if (update.docChanged || update.selectionSet || update.viewportChanged) this.decorations = decorations(update.view, generation);
    }
  }, { decorations: plugin => plugin.decorations });
}

function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 32_768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32_768));
  return btoa(binary);
}

function meaningfulAlt(filename: string): string | undefined {
  const suggestion = filename.replace(/\.[^.]+$/u, "").replace(/[-_]+/gu, " ").trim();
  const entered = window.prompt("Describe this image for readers", suggestion)?.trim();
  return entered || undefined;
}

export function imageInputs(importImage: (request: ImageImportRequest) => Promise<ImageImportResult | undefined>): Extension {
  const handle = async (view: EditorView, event: ClipboardEvent | DragEvent): Promise<void> => {
    const transfer = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer;
    const file = [...(transfer?.files ?? [])].find(item => item.type.startsWith("image/"));
    if (!file) return;
    event.preventDefault();
    const altText = meaningfulAlt(file.name || "image");
    if (!altText) return;
    const linkInPlace = event instanceof DragEvent && event.altKey;
    const uri = transfer?.getData("text/uri-list").split(/\r?\n/u).find(line => line.startsWith("file://"));
    const request: ImageImportRequest = linkInPlace && uri
      ? { filename: file.name, mimeType: file.type, sourceURL: uri, altText, linkInPlace: true }
      : { filename: file.name, mimeType: file.type, dataBase64: base64(await file.arrayBuffer()), altText, linkInPlace: false };
    const imported = await importImage(request);
    if (!imported) return;
    const position = view.state.selection.main.from;
    const markdown = `![${imported.altText}](${imported.path})`;
    view.dispatch({ changes: { from: view.state.selection.main.from, to: view.state.selection.main.to, insert: markdown }, selection: { anchor: position + markdown.length }, userEvent: event instanceof ClipboardEvent ? "input.paste" : "input.drop" });
    view.focus();
  };
  return EditorView.domEventHandlers({
    paste(event, view) { if ([...(event.clipboardData?.files ?? [])].some(file => file.type.startsWith("image/"))) { void handle(view, event); return true; } return false; },
    drop(event, view) { if ([...(event.dataTransfer?.files ?? [])].some(file => file.type.startsWith("image/"))) { void handle(view, event); return true; } return false; },
  });
}
