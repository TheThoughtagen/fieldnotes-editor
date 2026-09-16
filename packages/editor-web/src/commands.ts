import { renderDocument } from "@cruciblesoftware/fieldnotes-renderer";
export type AppCommand = "focus" | "source" | "preview" | "cycleMode" | "toggleVim" | "save" | "quit";
export interface FileResult { id: string; title: string }
export interface CommandPalette { open(mode: "files" | "commands" | "all"): void; destroy(): void }
interface Options {
  root: HTMLElement; source(): string; contextGeneration(): number;
  searchFiles(query: string, includeContent?: boolean): Promise<FileResult[]>; openFile(id: string): void;
  runCommand(command: AppCommand): void; navigate?(line: number): void;
}
interface Entry { title: string; activate(): void }
const commands: [AppCommand, string][] = [["focus", "Focus"], ["source", "Source"], ["preview", "Preview"], ["cycleMode", "Cycle mode"], ["toggleVim", "Toggle Vim"], ["save", "Save"], ["quit", "Close window"]];
let nextID = 0;
export function createCommandPalette(options: Options): CommandPalette {
  let dialog: HTMLElement | undefined, input: HTMLInputElement, list: HTMLElement;
  let previous: HTMLElement | null = null, composing = false, serial = 0, selected = 0;
  let entries: Entry[] = [], mode: "files" | "commands" | "all" = "all";
  const close = () => { serial++; dialog?.remove(); dialog = undefined; previous?.focus(); };
  const select = () => {
    [...list.children].forEach((child, index) => child.setAttribute("aria-selected", String(index === selected)));
    if (entries.length) input.setAttribute("aria-activedescendant", `${list.id}-${selected}`);
    else input.removeAttribute("aria-activedescendant");
  };
  const activate = (index: number) => { const entry = entries[index]; if (entry) { close(); entry.activate(); } };
  const refresh = async () => {
    const token = ++serial, generation = options.contextGeneration(), query = input.value.toLocaleLowerCase();
    const results: Entry[] = mode === "files" ? [] : commands.map(([command, title]) => ({ title, activate: () => options.runCommand(command) }));
    const files = mode === "commands" ? Promise.resolve([]) : options.searchFiles(query, mode === "all").catch(() => []);
    if (mode === "all") {
      const source = options.source();
      const rendered = await renderDocument(source, { allowRemoteImages: false });
      const lineFor = (text: string) => { const index = source.indexOf(text); return index < 0 ? 1 : source.slice(0, index).split("\n").length; };
      const add = (title: string) => results.push({ title, activate: () => options.navigate?.(lineFor(title)) });
      const headings = (items: typeof rendered.toc) => { for (const item of items) { add(item.text); headings(item.children); } };
      headings(rendered.toc);
      const html = document.createElement("template"); html.innerHTML = rendered.html;
      for (const link of html.content.querySelectorAll("a[href]")) add(link.textContent || link.getAttribute("href") || "Link");
      if (Array.isArray(rendered.frontmatter.tags)) for (const tag of rendered.frontmatter.tags) if (typeof tag === "string") add(tag);
    }
    const native = await files;
    if (!dialog || token !== serial || generation !== options.contextGeneration()) return;
    results.push(...native.map(file => ({ title: file.title, activate: () => options.openFile(file.id) })));
    entries = results.filter(entry => entry.title.toLocaleLowerCase().includes(query)).slice(0, 100);
    selected = 0; list.replaceChildren();
    entries.forEach((entry, index) => {
      const option = document.createElement("div"); option.id = `${list.id}-${index}`; option.setAttribute("role", "option"); option.textContent = entry.title;
      option.addEventListener("click", () => activate(index)); list.append(option);
    }); select();
  };
  const open: CommandPalette["open"] = next => {
    if (dialog) close();
    mode = next; previous = document.activeElement as HTMLElement | null; composing = false;
    dialog = document.createElement("section"); dialog.className = "fieldnotes-command-palette"; dialog.setAttribute("role", "dialog"); dialog.setAttribute("aria-modal", "true");
    const label = next === "files" ? "Open workspace file" : next === "commands" ? "App commands" : "Search workspace";
    dialog.setAttribute("aria-label", label);
    input = document.createElement("input"); input.setAttribute("role", "combobox"); input.setAttribute("aria-label", label); input.setAttribute("aria-expanded", "true"); input.setAttribute("aria-autocomplete", "list");
    list = document.createElement("div"); list.id = `fieldnotes-results-${++nextID}`; list.setAttribute("role", "listbox"); input.setAttribute("aria-controls", list.id);
    dialog.append(input, list); options.root.append(dialog);
    input.addEventListener("compositionstart", () => { composing = true; });
    input.addEventListener("compositionend", () => { composing = false; void refresh(); });
    input.addEventListener("input", event => { if (!composing && !(event as InputEvent).isComposing) void refresh(); });
    input.addEventListener("keydown", event => {
      if (composing || event.isComposing) return;
      if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); }
      if (event.key === "Enter") { event.preventDefault(); activate(selected); }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); selected = Math.max(0, Math.min(entries.length - 1, selected + (event.key === "ArrowDown" ? 1 : -1))); select(); }
      if (event.key === "Tab") { event.preventDefault(); input.focus(); }
    }); input.focus(); void refresh();
  };
  const keydown = (event: KeyboardEvent) => {
    if (!event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
    const key = event.key.toLowerCase();
    if (key !== "p" && (key !== "k" || event.shiftKey)) return;
    event.preventDefault(); event.stopPropagation(); open(key === "k" ? "all" : event.shiftKey ? "commands" : "files");
  };
  window.addEventListener("keydown", keydown, true);
  return { open, destroy() { close(); window.removeEventListener("keydown", keydown, true); } };
}
