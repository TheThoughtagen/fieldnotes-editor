import { EditorState, Extension, RangeSetBuilder } from "@codemirror/state";
import { syntaxTree } from "@codemirror/language";
import { Decoration, DecorationSet, EditorView, ViewPlugin, ViewUpdate, WidgetType } from "@codemirror/view";
import type { ImageImportRequest, ImageImportResult } from "./bridge.js";

export interface ImagePolicy { generation: number; allowRemoteImages: boolean; }
interface MarkdownImage { from: number; to: number; alt: string; path: string; }

export function resourceURL(path: string, generation: number): string | null {
  const value = path.trim();
  if (!value || value.startsWith("/") || value.startsWith("\\") || value.includes("\\") || /^[a-z][a-z0-9+.-]*:/iu.test(value)) return null;
  const parts = value.split("/");
  if (parts.some(part => !part || part === ".")) return null;
  const encoded = parts.map(part => encodeURIComponent(part)).join("/");
  return generation > 0 ? `fieldnotes-resource://${generation}/resource?path=${encodeURIComponent(value)}` : null;
}

function failedImage(image: HTMLImageElement, unresolved: string, onFailure?: (message: string) => void): void {
  if (image.dataset.failed === "true") return;
  image.dataset.failed = "true"; image.removeAttribute("src"); image.hidden = true;
  const placeholder = document.createElement("span"); placeholder.className = "fn-image-error";
  placeholder.textContent = `${image.alt || "Image"} — ${unresolved}`; image.after(placeholder);
  onFailure?.(`Image unavailable: ${unresolved}`);
}

export function rewritePreviewImages(root: ParentNode, policy: ImagePolicy, onFailure?: (message: string) => void): void {
  for (const image of root.querySelectorAll<HTMLImageElement>("img[src]")) {
    const raw = image.getAttribute("src") ?? "";
    if (raw.startsWith("data:")) continue;
    if (/^https:\/\//iu.test(raw)) {
      if (!policy.allowRemoteImages) failedImage(image, raw, onFailure);
      else image.addEventListener("error", () => failedImage(image, raw, onFailure), { once: true });
      continue;
    }
    const local = resourceURL(raw, policy.generation);
    if (!local) { failedImage(image, raw, onFailure); continue; }
    image.setAttribute("src", local);
    image.addEventListener("error", () => failedImage(image, raw, onFailure), { once: true });
  }
}

const normalizedLabel = (value: string): string => value.slice(1, -1).trim().replace(/\s+/gu, " ").toLowerCase();
const unescapeLabel = (value: string): string => value.replace(/\\(.)/gu, "$1");
const destination = (value: string): string => {
  const trimmed = value.trim();
  const unwrapped = trimmed.startsWith("<") && trimmed.endsWith(">") ? trimmed.slice(1, -1) : trimmed;
  return unwrapped.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/gu, "$1");
};

export function markdownImages(state: EditorState): MarkdownImage[] {
  const references = new Map<string, string>();
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== "LinkReference") return;
    const label = node.node.getChild("LinkLabel"), url = node.node.getChild("URL");
    if (label && url) references.set(normalizedLabel(state.sliceDoc(label.from, label.to)), destination(state.sliceDoc(url.from, url.to)));
  } });
  const images: MarkdownImage[] = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== "Image") return;
    const marks = node.node.getChildren("LinkMark");
    const closeAlt = marks.find(mark => state.sliceDoc(mark.from, mark.to) === "]");
    const url = node.node.getChild("URL"), reference = node.node.getChild("LinkLabel");
    if (!closeAlt) return;
    const alt = unescapeLabel(state.sliceDoc(node.from + 2, closeAlt.from));
    const referenceText = reference ? state.sliceDoc(reference.from, reference.to) : "";
    const referenceKey = referenceText === "[]" || !reference ? `[${alt}]` : referenceText;
    const path = url ? destination(state.sliceDoc(url.from, url.to)) : references.get(normalizedLabel(referenceKey));
    if (!path) return;
    images.push({ from: node.from, to: node.to, alt, path });
  } });
  return images;
}

class ImageWidget extends WidgetType {
  constructor(readonly image: MarkdownImage, readonly generation: number, readonly allowRemote: boolean) { super(); }
  eq(other: ImageWidget): boolean {
    return this.image.from === other.image.from && this.image.to === other.image.to && this.image.alt === other.image.alt
      && this.image.path === other.image.path && this.generation === other.generation && this.allowRemote === other.allowRemote;
  }
  toDOM(view: EditorView): HTMLElement {
    const wrapper = document.createElement("span"); wrapper.className = "fn-image-widget fn-image-loading";
    wrapper.setAttribute("role", "button"); wrapper.tabIndex = 0;
    wrapper.setAttribute("aria-label", `${this.image.alt || "Image"}: ${this.image.path}`);
    const image = document.createElement("img"); image.alt = this.image.alt;
    const remote = /^https:\/\//iu.test(this.image.path);
    const source = remote && this.allowRemote ? this.image.path : resourceURL(this.image.path, this.generation);
    const label = document.createElement("span"); label.className = "fn-image-label";
    label.textContent = `${this.image.alt || "Image"} — ${this.image.path}`; wrapper.append(image, label);
    const fail = () => { wrapper.classList.remove("fn-image-loading"); wrapper.classList.add("fn-image-error"); };
    if (source) image.src = source; else fail();
    image.addEventListener("load", () => wrapper.classList.remove("fn-image-loading")); image.addEventListener("error", fail);
    const select = () => { view.dispatch({ selection: { anchor: this.image.from, head: this.image.to }, scrollIntoView: true }); view.focus(); };
    wrapper.addEventListener("click", select);
    wrapper.addEventListener("keydown", event => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); select(); } });
    return wrapper;
  }
  ignoreEvent(): boolean { return false; }
}

function decorations(view: EditorView, generation: number, allowRemote: boolean): DecorationSet {
  const builder = new RangeSetBuilder<Decoration>(), selection = view.state.selection.main;
  for (const image of markdownImages(view.state)) {
    if (!view.visibleRanges.some(range => image.from <= range.to && image.to >= range.from)) continue;
    const selected = selection.from <= image.to && selection.to >= image.from && (selection.from !== selection.to || selection.head >= image.from && selection.head <= image.to);
    if (!selected) builder.add(image.from, image.to, Decoration.replace({ widget: new ImageWidget(image, generation, allowRemote) }));
  }
  return builder.finish();
}

export function focusImages(generation: () => number = () => 0, allowRemote: () => boolean = () => false): Extension {
  return ViewPlugin.fromClass(class {
    decorations: DecorationSet; currentGeneration: number; currentRemote: boolean;
    constructor(view: EditorView) { this.currentGeneration = generation(); this.currentRemote = allowRemote(); this.decorations = decorations(view, this.currentGeneration, this.currentRemote); }
    update(update: ViewUpdate) {
      const nextGeneration = generation(), nextRemote = allowRemote();
      if (update.docChanged || update.selectionSet || update.viewportChanged || nextGeneration !== this.currentGeneration || nextRemote !== this.currentRemote) {
        this.currentGeneration = nextGeneration; this.currentRemote = nextRemote; this.decorations = decorations(update.view, nextGeneration, nextRemote);
      }
    }
  }, { decorations: plugin => plugin.decorations });
}

function base64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer); let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 32_768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32_768));
  return btoa(binary);
}
function meaningfulAlt(filename: string): string | undefined {
  const suggestion = filename.replace(/\.[^.]+$/u, "").replace(/[-_]+/gu, " ").trim();
  return window.prompt("Describe this image for readers", suggestion)?.trim() || undefined;
}
interface PendingRange { from: number; to: number; touched: boolean; active: boolean; }

export function imageInputs(importImage: (request: ImageImportRequest) => Promise<ImageImportResult | undefined>, reportDiagnostic: (message: string) => void = () => undefined): Extension {
  const pending = new Set<PendingRange>(); let destroyed = false, activeFileReads = 0;
  const mapper = ViewPlugin.fromClass(class {
    update(update: ViewUpdate) {
      if (!update.docChanged) return;
      for (const range of pending) {
        if (range.from !== range.to) update.changes.iterChangedRanges((fromA, toA) => { if (fromA < range.to && toA > range.from) range.touched = true; });
        if (range.from === range.to) {
          range.from = range.to = update.changes.mapPos(range.from, 1);
        } else {
          range.from = update.changes.mapPos(range.from, 1); range.to = update.changes.mapPos(range.to, -1);
        }
      }
    }
    destroy() { destroyed = true; for (const range of pending) range.active = false; pending.clear(); }
  });
  const handle = async (view: EditorView, event: ClipboardEvent | DragEvent): Promise<void> => {
    const transfer = event instanceof ClipboardEvent ? event.clipboardData : event.dataTransfer;
    const file = [...(transfer?.files ?? [])].find(item => item.type.startsWith("image/")); if (!file) return;
    event.preventDefault();
    const dropPosition = event instanceof DragEvent ? view.posAtCoords({ x: event.clientX, y: event.clientY }) : null;
    const selection = view.state.selection.main;
    const range: PendingRange = event instanceof DragEvent ? { from: dropPosition ?? selection.head, to: dropPosition ?? selection.head, touched: false, active: true } : { from: selection.from, to: selection.to, touched: false, active: true };
    pending.add(range);
    try {
      if (file.size > 20_000_000) { reportDiagnostic(`Image is too large: ${file.name}`); return; }
      const altText = meaningfulAlt(file.name || "image"); if (!altText) return;
      const linkInPlace = event instanceof DragEvent && event.altKey;
      const uri = transfer?.getData("text/uri-list").split(/\r?\n/u).find(line => line.startsWith("file://"));
      let request: ImageImportRequest;
      if (linkInPlace) request = { filename: file.name, mimeType: file.type, ...(uri ? { sourceURL: uri } : {}), altText, linkInPlace: true };
      else {
        if (activeFileReads >= 2) { reportDiagnostic("Too many image reads are pending"); return; }
        activeFileReads += 1;
        try { request = { filename: file.name, mimeType: file.type, dataBase64: base64(await file.arrayBuffer()), altText, linkInPlace: false }; }
        finally { activeFileReads -= 1; }
      }
      const imported = await importImage(request);
      if (!imported || destroyed || !range.active || range.touched) return;
      const markdown = `![${imported.altText}](${imported.path})`;
      view.dispatch({ changes: { from: range.from, to: range.to, insert: markdown }, selection: { anchor: range.from + markdown.length }, userEvent: event instanceof ClipboardEvent ? "input.paste" : "input.drop" }); view.focus();
    } catch (error) { reportDiagnostic(error instanceof Error ? `Image import failed: ${error.message}` : "Image import failed"); }
    finally { range.active = false; pending.delete(range); }
  };
  return [mapper, EditorView.domEventHandlers({
    paste(event, view) { if ([...(event.clipboardData?.files ?? [])].some(file => file.type.startsWith("image/"))) { void handle(view, event); return true; } return false; },
    drop(event, view) { if ([...(event.dataTransfer?.files ?? [])].some(file => file.type.startsWith("image/"))) { void handle(view, event); return true; } return false; },
  })];
}
