import { afterEach, expect, test, vi } from "vitest";
import { createCommandPalette, type CommandPalette } from "../src/commands.js";

let palette: CommandPalette | undefined;
afterEach(() => { palette?.destroy(); palette = undefined; document.body.replaceChildren(); });

function setup(overrides: Partial<Parameters<typeof createCommandPalette>[0]> = {}) {
  const host = document.createElement("main");
  const trigger = document.createElement("button"); trigger.textContent = "edit";
  host.append(trigger); document.body.append(host); trigger.focus();
  const runCommand = vi.fn(); const openFile = vi.fn();
  palette = createCommandPalette({
    root: host,
    source: () => "---\ntags: [swift, macOS]\n---\n\n## Setup\n### Details\n[Docs](https://example.test)",
    contextGeneration: () => 4,
    searchFiles: async () => [{ id: "8E6C65D4-6D34-42F5-A273-8F972865D15F", title: "notes/readme.md" }],
    openFile,
    runCommand,
    ...overrides,
  });
  return { host, trigger, runCommand, openFile };
}

test("exact shortcuts open an accessible palette and Escape restores focus", async () => {
  const { trigger } = setup();
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, altKey: true, bubbles: true }));
  expect(document.querySelector("[role=dialog]")).toBeNull();

  window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, bubbles: true }));
  const dialog = document.querySelector<HTMLElement>("[role=dialog]")!;
  const input = dialog.querySelector<HTMLInputElement>("[role=combobox]")!;
  expect(dialog.getAttribute("aria-modal")).toBe("true");
  expect(input.getAttribute("aria-controls")).toBe(dialog.querySelector("[role=listbox]")?.id);
  expect(input.getAttribute("aria-expanded")).toBe("true");
  expect(document.activeElement).toBe(input);
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  expect(document.querySelector("[role=dialog]")).toBeNull();
  expect(document.activeElement).toBe(trigger);
});

test("all mode filters files, H2/H3, links, tags, and closed commands", async () => {
  const { openFile, runCommand } = setup();
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "k", metaKey: true, bubbles: true }));
  const input = document.querySelector<HTMLInputElement>("[role=combobox]")!;
  await vi.waitFor(() => expect(document.querySelectorAll("[role=option]").length).toBeGreaterThanOrEqual(8));
  expect(document.querySelector("[role=listbox]")?.textContent).toContain("Setup");
  expect(document.querySelector("[role=listbox]")?.textContent).toContain("Details");
  expect(document.querySelector("[role=listbox]")?.textContent).toContain("Docs");
  expect(document.querySelector("[role=listbox]")?.textContent).toContain("swift");
  expect(document.querySelector("[role=listbox]")?.textContent).toContain("notes/readme.md");

  input.value = "preview"; input.dispatchEvent(new InputEvent("input", { bubbles: true, data: "preview" }));
  await vi.waitFor(() => expect(document.querySelectorAll("[role=option]")).toHaveLength(1));
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  expect(runCommand).toHaveBeenCalledWith("preview");
  expect(openFile).not.toHaveBeenCalled();
});

test("IME composition suppresses filtering and activation until composition ends", async () => {
  const { runCommand } = setup();
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "P", metaKey: true, shiftKey: true, bubbles: true }));
  const input = document.querySelector<HTMLInputElement>("[role=combobox]")!;
  input.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
  input.value = "preview"; input.dispatchEvent(new InputEvent("input", { bubbles: true, data: "preview", isComposing: true }));
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, isComposing: true }));
  expect(runCommand).not.toHaveBeenCalled();
  input.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true }));
  await vi.waitFor(() => expect(document.querySelectorAll("[role=option]")).toHaveLength(1));
});

test("stale native generations are ignored and file selections return only opaque IDs", async () => {
  let generation = 1;
  let resolve!: (value: { id: string; title: string }[]) => void;
  const searchFiles = vi.fn(() => new Promise<{ id: string; title: string }[]>(done => { resolve = done; }));
  const { openFile } = setup({ contextGeneration: () => generation, searchFiles });
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, bubbles: true }));
  generation = 2;
  resolve([{ id: "40D89A96-E755-46FF-B7D5-451E1238FEC1", title: "/private/secret.md" }]);
  await new Promise(done => setTimeout(done, 0));
  expect(document.querySelector("[role=listbox]")?.textContent).not.toContain("secret");

  palette?.destroy(); palette = undefined;
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true, bubbles: true }));
  expect(document.querySelector("[role=dialog]")).toBeNull();
  expect(openFile).not.toHaveBeenCalled();
});
