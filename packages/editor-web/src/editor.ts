import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { html } from "@codemirror/lang-html";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { bracketMatching, defaultHighlightStyle, indentOnInput, LanguageDescription, syntaxHighlighting, syntaxTree } from "@codemirror/language";
import { lintKeymap } from "@codemirror/lint";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, Extension } from "@codemirror/state";
import { Decoration, DecorationSet, drawSelection, dropCursor, EditorView, highlightActiveLine, highlightSpecialChars, keymap, lineNumbers, ViewPlugin, ViewUpdate } from "@codemirror/view";
import { getCM, vim, Vim } from "@replit/codemirror-vim";
import { hydrateMermaid } from "@cruciblesoftware/fieldnotes-renderer/browser";
import { renderDocument } from "@cruciblesoftware/fieldnotes-renderer";
import { createNativeBridge, EditorStatus, NativeBridge } from "./bridge.js";
import "@cruciblesoftware/fieldnotes-renderer/styles.css";
import "./editor.css";
import { locateMarkdownTagObject } from "./markdown-tag-object.js";

export type PresentationMode = "focus" | "source" | "preview";
export interface EditorController {
  readonly view: EditorView;
  readonly mode: PresentationMode;
  readonly vimEnabled: boolean;
  setMode(mode: PresentationMode): void;
  cycleMode(): void;
  setVimEnabled(enabled: boolean): void;
  destroy(): void;
}
interface EditorOptions {
  initialDocument?: string;
  onStatus?: (status: EditorStatus) => void;
  render?: typeof renderDocument;
  hydrate?: typeof hydrateMermaid;
}

const editorByView = new WeakMap<EditorView, { bridge: NativeBridge }>();
let exCommandsInstalled = false;
function installNativeExCommands(): void {
  if (exCommandsInstalled) return;
  exCommandsInstalled = true;
  const unsupported = (cm: Parameters<Parameters<typeof Vim.defineEx>[2]>[0], command: string): void => {
    const notice = document.createElement("div");
    notice.className = "fieldnotes-vim-diagnostic";
    notice.setAttribute("role", "status");
    notice.textContent = `Unsupported Vim command: ${command}`;
    cm.openNotification(notice, { bottom: true, duration: 4000 });
  };
  for (const [name, prefix, action] of [["write", "w", "save"], ["quit", "q", "quit"]] as const) {
    Vim.defineEx(name, prefix, (cm, params) => {
      if ((params.argString ?? "").trim() || (params.input ?? name).includes("!")) { unsupported(cm, params.input ?? name); return; }
      const context = editorByView.get(cm.cm6 as EditorView);
      if (context) void context.bridge.requestAction(action);
    });
  }
  for (const [name, prefix] of [["map", "map"], ["nmap", "nmap"], ["imap", "imap"], ["vmap", "vmap"], ["source", "source"], ["function", "function"], ["let", "let"], ["edit", "edit"], ["read", "read"], ["file", "file"], ["buffer", "buffer"], ["bnext", "bnext"], ["bdelete", "bdelete"], ["split", "split"], ["vsplit", "vsplit"], ["tabnew", "tabnew"], ["close", "close"], ["wq", "wq"], ["xit", "x"], ["!", "!"]] as const) {
    Vim.defineEx(name, prefix, (cm, params) => unsupported(cm, params.input));
  }
  Vim.defineEx("set", "se", (cm, params) => {
    const options = (params.argString ?? "").trim().split(/\s+/u).filter(Boolean);
    if (!options.length) { unsupported(cm, params.input); return; }
    for (const raw of options) {
      const disabled = raw.startsWith("no"), name = disabled ? raw.slice(2) : raw;
      if (!["ignorecase", "smartcase", "hlsearch"].includes(name)) { unsupported(cm, params.input); return; }
      Vim.setOption(name, !disabled, cm);
    }
  });
  Vim.defineMotion("fieldnotesInnerTag", (cm, head) => {
    const view = cm.cm6 as EditorView;
    const range = locateMarkdownTagObject(view.state, cm.indexFromPos(head), false);
    return range ? [cm.posFromIndex(range.from), cm.posFromIndex(range.to)] : head;
  });
  Vim.defineMotion("fieldnotesAroundTag", (cm, head) => {
    const view = cm.cm6 as EditorView;
    const range = locateMarkdownTagObject(view.state, cm.indexFromPos(head), true);
    return range ? [cm.posFromIndex(range.from), cm.posFromIndex(range.to)] : head;
  });
  Vim.mapCommand("it", "motion", "fieldnotesInnerTag", { textObjectInner: true }, {});
  Vim.mapCommand("at", "motion", "fieldnotesAroundTag", {}, {});
}

function focusDecorations(view: EditorView): DecorationSet {
  const ranges: ReturnType<Decoration["range"]>[] = [];
  const cursor = view.state.selection.main.head;
  const document = view.state.doc.toString();
  const frontmatter = /^---\n[\s\S]*?\n---(?=\n|$)/u.exec(document);
  if (frontmatter) {
    ranges.push(Decoration.mark({ class: cursor <= frontmatter[0].length ? "fn-syntax-active fn-frontmatter" : "fn-syntax-muted fn-frontmatter" }).range(0, frontmatter[0].length));
  }
  for (const visible of view.visibleRanges) syntaxTree(view.state).iterate({
    from: visible.from, to: visible.to,
    enter(node) {
      if (/Mark$|Frontmatter|YAML/i.test(node.name)) {
        const parent = node.node.parent;
        const active = cursor >= (parent?.from ?? node.from) && cursor <= (parent?.to ?? node.to);
        ranges.push(Decoration.mark({ class: active ? "fn-syntax-active" : "fn-syntax-muted" }).range(node.from, node.to));
      }
      if (/^(ATXHeading|SetextHeading|FencedCode|Blockquote)/.test(node.name)) {
        ranges.push(Decoration.line({ class: `fn-${node.name.toLowerCase()}` }).range(view.state.doc.lineAt(node.from).from));
      }
    },
  });
  return Decoration.set(ranges, true);
}
const focusPlugin = ViewPlugin.fromClass(class {
  decorations: DecorationSet;
  constructor(view: EditorView) { this.decorations = focusDecorations(view); }
  update(update: ViewUpdate) { if (update.docChanged || update.selectionSet || update.viewportChanged) this.decorations = focusDecorations(update.view); }
}, { decorations: value => value.decorations });
const focusExtension: Extension = [focusPlugin, EditorView.editorAttributes.of({ class: "fieldnotes-focus" })];
const sourceExtension: Extension = EditorView.editorAttributes.of({ class: "fieldnotes-source" });

export function createEditor(root: HTMLElement, options: EditorOptions = {}): EditorController {
  root.replaceChildren(); root.dataset.booted = "true"; root.removeAttribute("role");
  const editorHost = document.createElement("div"); editorHost.className = "fieldnotes-editor-host";
  const preview = document.createElement("article"); preview.className = "fieldnotes-preview"; preview.hidden = true;
  preview.contentEditable = "false"; preview.setAttribute("aria-label", "Rendered Markdown preview");
  root.append(editorHost, preview);
  const presentation = new Compartment(); const vimMode = new Compartment();
  let mode: PresentationMode = "focus", vimEnabled = true, destroyed = false, renderToken = 0, vimState = "normal";
  let bridge!: NativeBridge; let statusTimer: number | undefined; let renderPreview!: () => Promise<void>;
  const publishStatus = (view: EditorView): void => {
    if (destroyed) return;
    if (statusTimer !== undefined) window.clearTimeout(statusTimer);
    statusTimer = window.setTimeout(() => {
      const position = view.state.selection.main.head, line = view.state.doc.lineAt(position), text = view.state.doc.toString().trim();
      const status: EditorStatus = { presentationMode: mode, vimMode: vimEnabled ? vimState : "off", line: line.number, column: position - line.from + 1, wordCount: text ? text.split(/\s+/u).length : 0 };
      options.onStatus?.(status); bridge?.postStatus(status);
    }, 15);
  };
  const state = EditorState.create({ doc: options.initialDocument ?? "# FIELDNOTES\n\n", extensions: [
    EditorState.allowMultipleSelections.of(true),
    vimMode.of(vim()), lineNumbers(), highlightSpecialChars(), history(), drawSelection(), dropCursor(), indentOnInput(), bracketMatching(), closeBrackets(), autocompletion(), highlightActiveLine(), highlightSelectionMatches(),
    markdown({ base: markdownLanguage, codeLanguages: [LanguageDescription.of({ name: "HTML", extensions: ["html"], load: async () => html() })] }), syntaxHighlighting(defaultHighlightStyle, { fallback: true }), presentation.of(focusExtension),
    keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...completionKeymap, ...lintKeymap, indentWithTab]),
    EditorView.contentAttributes.of({ "aria-label": "Markdown source" }), EditorView.lineWrapping,
    EditorView.updateListener.of(update => {
      if (update.docChanged && mode === "preview") void renderPreview();
      if (update.docChanged || update.selectionSet) publishStatus(update.view);
    }),
  ] });
  const view = new EditorView({ state, parent: editorHost }); bridge = createNativeBridge(view); editorByView.set(view, { bridge }); installNativeExCommands();
  let adapter = getCM(view);
  const onVimModeChange = (event: { mode?: string }) => { vimState = typeof event?.mode === "string" ? event.mode : "normal"; publishStatus(view); };
  const attachVimListener = (): void => { adapter?.on("vim-mode-change", onVimModeChange); };
  const detachVimListener = (): void => { adapter?.off("vim-mode-change", onVimModeChange); };
  attachVimListener();
  renderPreview = async (): Promise<void> => {
    const token = ++renderToken, detached = document.createElement("article");
    try {
      const result = await (options.render ?? renderDocument)(view.state.doc.toString(), { allowRemoteImages: false });
      if (destroyed || token !== renderToken) return;
      detached.innerHTML = result.html;
      for (const image of detached.querySelectorAll<HTMLImageElement>("img[src]")) {
        if (!image.src.startsWith("data:")) image.removeAttribute("src");
      }
      detached.querySelectorAll("iframe").forEach(frame => frame.remove());
      detached.className = "fieldnotes-render-stage";
      detached.setAttribute("aria-hidden", "true");
      detached.inert = true;
      document.body.append(detached);
      try {
        await (options.hydrate ?? hydrateMermaid)(detached);
      } finally {
        detached.remove();
      }
      if (!destroyed && token === renderToken) preview.replaceChildren(...detached.childNodes);
    } catch (error) {
      if (destroyed || token !== renderToken) return;
      const message = document.createElement("p"); message.className = "fieldnotes-preview-error";
      message.textContent = error instanceof Error ? error.message : "Preview could not be rendered."; preview.replaceChildren(message);
    }
  };
  const setMode = (next: PresentationMode): void => {
    if (destroyed || next === mode) return;
    mode = next; root.dataset.mode = next; preview.hidden = next !== "preview"; editorHost.hidden = next === "preview";
    view.dispatch({ effects: presentation.reconfigure(next === "focus" ? focusExtension : sourceExtension) });
    if (next === "preview") void renderPreview(); else view.focus(); publishStatus(view);
  };
  const cycleMode = () => setMode(mode === "focus" ? "source" : mode === "source" ? "preview" : "focus");
  const setVimEnabled = (enabled: boolean): void => {
    if (destroyed || vimEnabled === enabled) return;
    detachVimListener();
    vimEnabled = enabled; view.dispatch({ effects: vimMode.reconfigure(enabled ? vim() : []) });
    adapter = getCM(view);
    attachVimListener();
    vimState = enabled ? "normal" : "off"; publishStatus(view);
  };
  const onKeyDown = (event: KeyboardEvent): void => {
    if (!event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
    const actions: Record<string, () => void> = { "1": () => setMode("focus"), "2": () => setMode("source"), "3": () => setMode("preview"), "\\": cycleMode };
    const action = actions[event.key]; if (action) { event.preventDefault(); action(); }
  };
  const onPreviewClick = (event: MouseEvent): void => {
    const anchor = (event.target as Element | null)?.closest<HTMLAnchorElement>('a[href^="#"]');
    if (!anchor) return;
    event.preventDefault();
    let id: string;
    try { id = decodeURIComponent(anchor.hash.slice(1)); } catch { return; }
    if (id) preview.querySelector<HTMLElement>(`#${CSS.escape(id)}`)?.scrollIntoView();
  };
  preview.addEventListener("click", onPreviewClick);
  window.addEventListener("keydown", onKeyDown); root.dataset.mode = mode; publishStatus(view);
  const controller: EditorController = { view, get mode() { return mode; }, get vimEnabled() { return vimEnabled; }, setMode, cycleMode, setVimEnabled,
    destroy() { if (destroyed) return; destroyed = true; renderToken += 1; window.removeEventListener("keydown", onKeyDown); preview.removeEventListener("click", onPreviewClick); if (statusTimer !== undefined) window.clearTimeout(statusTimer); detachVimListener(); editorByView.delete(view); bridge.destroy(); view.destroy(); root.replaceChildren(); },
  };
  const snapshotAPI = window.fieldnotes;
  Object.defineProperty(window, "fieldnotes", { configurable: true, enumerable: false, writable: false, value: Object.freeze({
    applyNativeSnapshot: snapshotAPI.applyNativeSnapshot,
    setMode(value: unknown) { if (value === "focus" || value === "source" || value === "preview") { setMode(value); return true; } return false; },
    cycleMode() { cycleMode(); },
    setVimEnabled(value: unknown) { if (typeof value !== "boolean") return false; setVimEnabled(value); return true; },
    toggleVim() { setVimEnabled(!vimEnabled); },
    destroy() { controller.destroy(); },
  }) });
  return controller;
}
