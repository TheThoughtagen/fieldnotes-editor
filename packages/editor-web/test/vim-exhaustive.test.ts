import { expect, test } from "vitest";
import { userEvent } from "vitest/browser";
import matrix from "../../../vim-compatibility.json";
import tokenManifest from "../../../vim-token-manifest.json";
import { createEditor } from "../src/editor.js";

type Classification = "supported" | "adapted" | "unsupported";
type Case = {
  row: string;
  token: string;
  keys: string;
  source: string;
  anchor?: number;
  expectedDocument: string;
  expectedAnchor?: number;
  expectedMode?: string;
  classification?: Classification;
  nativeAction?: "save" | "quit";
};

const c = (row: string, token: string, keys: string, source: string, expectedDocument = source, anchor = 0, expectedAnchor?: number): Case =>
  ({ row, token, keys, source, anchor, expectedDocument, ...(expectedAnchor === undefined ? {} : { expectedAnchor }) });

const cases: Case[] = [
  { ...c("modes", "normal", "{Escape}", "abc", "abc", 1, 1), expectedMode: "normal" },
  { ...c("modes", "insert", "i", "abc", "abc", 0, 0), expectedMode: "insert" },
  { ...c("modes", "replace", "R", "abc", "abc", 0, 0), expectedMode: "replace" },

  c("motions-basic", "h", "h", "abc", "abc", 2, 1), c("motions-basic", "j", "j", "abc\ndef", "abc\ndef", 0, 4),
  c("motions-basic", "k", "k", "abc\ndef", "abc\ndef", 4, 0), c("motions-basic", "l", "l", "abc", "abc", 0, 1),
  c("motions-word", "w", "w", "one two", "one two", 0, 4), c("motions-word", "W", "W", "one two", "one two", 0, 4),
  c("motions-word", "b", "b", "one two", "one two", 5, 4), c("motions-word", "B", "B", "one two", "one two", 5, 4),
  c("motions-word", "e", "e", "one two", "one two", 0, 2), c("motions-word", "E", "E", "one two", "one two", 0, 2),
  c("motions-line", "0", "0", "  abc", "  abc", 4, 0), c("motions-line", "^", "^", "  abc", "  abc", 0, 2), c("motions-line", "$", "$", "  abc", "  abc", 0, 4),
  c("motions-document", "gg", "gg", "a\nb\nc", "a\nb\nc", 2, 0), c("motions-document", "G", "G", "a\nb\nc", "a\nb\nc", 0, 4),
  c("motions-find", "f", "fx", "abxcd", "abxcd", 0, 2), c("motions-find", "F", "Fx", "xabxc", "xabxc", 4, 3),
  c("motions-find", "t", "tx", "abxcd", "abxcd", 0, 1), c("motions-find", "T", "Tx", "xabxc", "xabxc", 4, 4),
  c("motions-find", ";", "fx;", "abxcx", "abxcx", 0, 4), c("motions-find", ",", "fx,", "xabxc", "xabxc", 0, 0),
  c("motions-pairs", "%", "%", "(ab)", "(ab)", 0, 3),
  c("motions-blocks", "{", "{{", "one\n\ntwo", "one\n\ntwo", 5, 4), c("motions-blocks", "}", "}}", "one\n\ntwo", "one\n\ntwo", 0, 5),
  c("motions-blocks", "(", "(", "One. Two.", "One. Two.", 5, 0), c("motions-blocks", ")", ")", "One. Two.", "One. Two.", 0, 5),
  c("motions-screen", "H", "H", "a\nb\nc", "a\nb\nc", 2), c("motions-screen", "M", "M", "a\nb\nc", "a\nb\nc", 0), c("motions-screen", "L", "L", "a\nb\nc", "a\nb\nc", 0),
  c("motions-scroll", "Ctrl-f", "{Control>}f{/Control}", "a\nb\nc", "a\nb\nc"), c("motions-scroll", "Ctrl-b", "{Control>}b{/Control}", "a\nb\nc", "a\nb\nc", 4),
  c("motions-scroll", "Ctrl-d", "{Control>}d{/Control}", "a\nb\nc", "a\nb\nc"), c("motions-scroll", "Ctrl-u", "{Control>}u{/Control}", "a\nb\nc", "a\nb\nc", 4),

  c("operator-delete", "d{motion}", "dw", "one two", "two"), c("operator-change", "c{motion}", "cwX{Escape}", "one two", "X two"),
  c("operator-yank", "y{motion}", "ywp", "one two", "oone ne two"), c("operator-counts", "{count}{operator}{motion}", "2dw", "one two three", "three"),
  c("operator-double", "dd", "dd", "one\ntwo", "two"), c("operator-double", "cc", "ccX{Escape}", "one\ntwo", "X\ntwo"), c("operator-double", "yy", "yyp", "one\ntwo", "one\none\ntwo"),

  c("text-words", "iw", "diw", "one two", " two"), c("text-words", "aw", "daw", "one two", "two"),
  c("text-words", "iW", "diW", "one-two three", " three"), c("text-words", "aW", "daW", "one-two three", "three"),
  c("text-sentences", "is", "dis", "One. Two.", " Two."), c("text-sentences", "as", "das", "One. Two.", "Two."),
  c("text-paragraphs", "ip", "dip", "one\nline\n\ntwo", "\ntwo"), c("text-paragraphs", "ap", "dap", "one\nline\n\ntwo", "two"),
  c("text-pairs", "i(", "di(", "(one)", "()", 2), c("text-pairs", "a(", "da(", "x(one)y", "xy", 3),
  c("text-pairs", "i[", "di[BracketLeft]", "[one]", "[]", 2), c("text-pairs", "a[", "da[BracketLeft]", "x[one]y", "xy", 3),
  c("text-pairs", "i{", "di{{", "{one}", "{}", 2), c("text-pairs", "a{", "da{{", "x{one}y", "xy", 3),
  c("text-pairs", "i<", "di<", "<one>", "<>", 2), c("text-pairs", "a<", "da<", "x<one>y", "xy", 3),
  c("text-quotes", "i\"", "di\"", "\"one\"", "\"\"", 2), c("text-quotes", "a\"", "da\"", "x\"one\"y", "xy", 3),
  c("text-quotes", "i'", "di'", "'one'", "''", 2), c("text-quotes", "a'", "da'", "x'one'y", "xy", 3),
  c("text-quotes", "i`", "di`", "`one`", "``", 2), c("text-quotes", "a`", "da`", "x`one`y", "xy", 3),
  { ...c("text-tags", "it", "dit", "<p>one</p>", "<p></p>", 4), classification: "adapted" },
  { ...c("text-tags", "at", "dat", "x<p>one</p>y", "xy", 5), classification: "adapted" },

  c("edits-insert", "i", "iX{Escape}", "abc", "Xabc"), c("edits-insert", "a", "aX{Escape}", "abc", "aXbc"),
  c("edits-insert", "I", "IX{Escape}", "  abc", "  Xabc", 4), c("edits-insert", "A", "AX{Escape}", "abc", "abcX"),
  c("edits-open", "o", "oX{Escape}", "abc", "abc\nX"), c("edits-open", "O", "OX{Escape}", "abc", "X\nabc"),
  c("edits-replace", "r", "rX", "abc", "Xbc"), c("edits-replace", "R", "RX{Escape}", "abc", "Xbc"),
  c("edits-replace", "s", "sX{Escape}", "abc", "Xbc"), c("edits-replace", "S", "SX{Escape}", "abc\ndef", "X\ndef"),
  c("edits-delete", "x", "x", "abc", "bc"), c("edits-delete", "X", "X", "abc", "bc", 1),
  c("edits-delete", "C", "CX{Escape}", "abc", "X", 0), c("edits-delete", "D", "D", "abc", "", 0),
  c("edits-lines", "J", "J", "one\ntwo", "one two"), c("edits-repeat", ".", "xiX{Escape}l.", "abcd", "XXbcd"),
  c("edits-undo", "u", "xu", "abc", "abc"), c("edits-undo", "Ctrl-r", "xu{Control>}r{/Control}", "abc", "bc"),
  c("edits-case", "~", "~", "Ab", "ab"), c("edits-indent", "<<", "<<", "  one", "one"),
  c("edits-indent", ">>", ">>", "one", "  one"), c("edits-indent", "=", "==", " one", " one"),

  c("registers", "\"a", "\"ayw", "one two", "one two"), c("registers", "\"_", "\"_dw", "one two", "two"),
  c("registers", "\"+", "\"+yw", "one two", "one two"), c("registers", "\"*", "\"*yw", "one two", "one two"),
  c("marks", "m{letter}", "ma", "one two", "one two"), c("marks", "'{letter}", "ma$'a", "one two", "one two", 0, 0),
  c("marks", "`{letter}", "lma$`a", "one two", "one two", 0, 1),
  c("macros", "q{register}", "qaix{Escape}q", "one", "xone"), c("macros", "@{register}", "qaix{Escape}q@a", "one", "xxone"),
  c("macros", "@@", "qaix{Escape}q@a@@", "one", "xxxone"),
  c("search-pattern", "/pattern", "/two{Enter}", "one two", "one two", 0, 4), c("search-pattern", "?pattern", "?one{Enter}", "one two", "one two", 4, 0),
  c("search-repeat", "n", "/one{Enter}n", "one one", "one one", 0, 0), c("search-repeat", "N", "/one{Enter}nN", "one one", "one one", 0, 4),
  c("search-word", "*", "*", "one one", "one one", 0, 4), c("search-word", "#", "#", "one one", "one one", 4, 0),
  c("ex-substitute", ":s", ":s/one/two/{Enter}", "one one", "two one"),
  c("ex-substitute-all", ":%s", ":%s/one/two/g{Enter}", "one\none", "two\ntwo"),
  c("ex-set", "ignorecase", ":set ignorecase{Enter}", "one"), c("ex-set", "smartcase", ":set smartcase{Enter}", "one"), c("ex-set", "hlsearch", ":set hlsearch{Enter}", "one"),
  c("ex-nohlsearch", ":noh", "/one{Enter}:noh{Enter}", "one"),

  { ...c("native-write", ":write", ":write{Enter}", "one"), classification: "adapted", nativeAction: "save" },
  { ...c("native-write", ":w", ":w{Enter}", "one"), classification: "adapted", nativeAction: "save" },
  { ...c("native-quit", ":quit", ":quit{Enter}", "one"), classification: "adapted", nativeAction: "quit" },
  { ...c("native-quit", ":q", ":q{Enter}", "one"), classification: "adapted", nativeAction: "quit" },
  { ...c("visual-character", "v", "v", "one"), expectedMode: "visual" },
  { ...c("visual-character", "vld", "vld", "abcd", "cd", 0, 0), expectedMode: "normal" },
  { ...c("visual-line", "V", "V", "one"), expectedMode: "visual" },
  { ...c("visual-line", "Vjd", "Vjd", "one\ntwo\nthree", "three", 0, 0), expectedMode: "normal" },
  { ...c("visual-block", "Ctrl-v", "{Control>}v{/Control}", "one"), expectedMode: "visual" },
  { ...c("visual-block", "Ctrl-v jld", "{Control>}v{/Control}jld", "abc\ndef", "c\nf", 0, 0), expectedMode: "normal" },
];

const unsupported: Array<[string, string, string]> = [
  ["unsupported-shell", ":!", ":!echo nope{Enter}"],
  ["unsupported-vimscript", ":source", ":source x{Enter}"], ["unsupported-vimscript", ":function", ":function X{Enter}"], ["unsupported-vimscript", ":let", ":let x=1{Enter}"],
  ["unsupported-map", ":map", ":map x y{Enter}"], ["unsupported-map", ":nmap", ":nmap x y{Enter}"], ["unsupported-map", ":imap", ":imap x y{Enter}"], ["unsupported-map", ":vmap", ":vmap x y{Enter}"],
  ["unsupported-file", ":edit", ":edit x{Enter}"], ["unsupported-file", ":read", ":read x{Enter}"], ["unsupported-file", ":file", ":file x{Enter}"],
  ["unsupported-buffer", ":buffer", ":buffer 2{Enter}"], ["unsupported-buffer", ":bnext", ":bnext{Enter}"], ["unsupported-buffer", ":bdelete", ":bdelete{Enter}"],
  ["unsupported-window", ":split", ":split{Enter}"], ["unsupported-window", ":vsplit", ":vsplit{Enter}"], ["unsupported-window", ":tabnew", ":tabnew{Enter}"], ["unsupported-window", ":close", ":close{Enter}"],
  ["unsupported-force", ":q!", ":q!{Enter}"], ["unsupported-force", ":w!", ":w!{Enter}"], ["unsupported-force", ":wq", ":wq{Enter}"], ["unsupported-force", ":x", ":x{Enter}"],
  ["unsupported-write-path", ":write {path}", ":write /tmp/nope{Enter}"],
];
cases.push(...unsupported.map(([row, token, keys]) => ({ ...c(row, token, keys, "unchanged"), classification: "unsupported" as const })));

const byRow = new Map<string, Case[]>();
for (const fixture of cases) {
  const declared = matrix.commands.find(command => command.id === fixture.row)?.classification as Classification | undefined;
  if (!declared) throw new Error(`missing matrix row: ${fixture.row}`);
  fixture.classification ??= declared;
  if (fixture.classification !== declared) throw new Error(`classification mismatch: ${fixture.row}/${fixture.token}`);
  byRow.set(fixture.row, [...(byRow.get(fixture.row) ?? []), fixture]);
}

test("every declared matrix row has concrete keyboard fixtures", () => {
  expect([...byRow.keys()].sort()).toEqual(matrix.commands.map(command => command.id).sort());
  for (const [row, tokens] of Object.entries(tokenManifest)) {
    expect(byRow.get(row)?.map(fixture => fixture.token).sort(), row).toEqual([...tokens].sort());
  }
  expect(cases).toHaveLength(144);
  expect(Object.fromEntries(["supported", "adapted", "unsupported"].map(classification => [classification, cases.filter(fixture => fixture.classification === classification).length])))
    .toEqual({ supported: 115, adapted: 6, unsupported: 23 });
});

test.each(cases)("$classification $row $token executes its declared keyboard contract", async fixture => {
  document.body.innerHTML = '<main id="editor"></main>';
  if (fixture.row === "registers" && (fixture.token === "\"+" || fixture.token === "\"*")) {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async () => undefined, readText: async () => "" } });
  }
  const messages: Array<Record<string, unknown>> = [];
  Object.defineProperty(window, "webkit", { configurable: true, value: fixture.classification === "adapted" && fixture.nativeAction || fixture.classification === "unsupported" ? {
    messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
      messages.push(message);
      if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "vim-doc", revision: 0, text: fixture.source, selection: { anchor: fixture.anchor ?? 0, head: fixture.anchor ?? 0 } });
      return Promise.resolve({ kind: "ack", documentID: "vim-doc", revision: 0 });
    } } },
  } : undefined });
  const statuses: string[] = [];
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: fixture.source, onStatus: status => statuses.push(status.vimMode) });
  if (fixture.anchor !== undefined) editor.view.dispatch({ selection: { anchor: fixture.anchor } });
  await new Promise(resolve => setTimeout(resolve, 30));
  editor.view.focus();
  await userEvent.keyboard(fixture.keys);
  await new Promise(resolve => setTimeout(resolve, 30));
  expect(editor.view.state.doc.toString()).toBe(fixture.expectedDocument);
  if (fixture.expectedAnchor !== undefined) expect(editor.view.state.selection.main.head).toBe(fixture.expectedAnchor);
  if (fixture.expectedMode !== undefined) expect(statuses.at(-1)).toBe(fixture.expectedMode);
  if (fixture.nativeAction) expect(messages.filter(message => message.kind === "action")).toEqual([
    expect.objectContaining({ payload: { action: fixture.nativeAction } }),
  ]);
  if (fixture.classification === "unsupported") {
    expect(messages.some(message => message.kind === "action")).toBe(false);
    expect(document.querySelector(".fieldnotes-vim-diagnostic")?.textContent).toContain("Unsupported Vim command");
  }
  editor.destroy();
  Object.defineProperty(window, "webkit", { configurable: true, value: undefined });
});

test(":write waits for the pending edit acknowledgement before its native action", async () => {
  document.body.innerHTML = '<main id="editor"></main>';
  let acknowledgeEdit!: (value: unknown) => void;
  const messages: Array<Record<string, unknown>> = [];
  Object.defineProperty(window, "webkit", { configurable: true, value: { messageHandlers: { native: { postMessage(message: Record<string, unknown>) {
    messages.push(message);
    if (message.kind === "ready") return Promise.resolve({ kind: "snapshot", documentID: "pending-doc", revision: 0, text: "one", selection: { anchor: 0, head: 0 } });
    if (message.kind === "transaction") return new Promise(resolve => { acknowledgeEdit = resolve; });
    return Promise.resolve({ kind: "ack", documentID: "pending-doc", revision: 1 });
  } } } } });
  const editor = createEditor(document.querySelector("#editor")!, { initialDocument: "one" });
  await expect.poll(() => editor.view.dom.dataset.bridgeState).toBe("ready");
  editor.view.focus();
  editor.view.dispatch({ changes: { from: 0, insert: "X" }, userEvent: "input.type" });
  expect(editor.view.state.doc.toString()).toBe("Xone");
  await expect.poll(() => messages.some(message => message.kind === "transaction")).toBe(true);
  await userEvent.keyboard(":write{Enter}");
  await new Promise(resolve => setTimeout(resolve, 30));
  expect(messages.some(message => message.kind === "action")).toBe(false);
  acknowledgeEdit({ kind: "ack", documentID: "pending-doc", revision: 1 });
  await expect.poll(() => messages.filter(message => message.kind === "action").length).toBe(1);
  expect(messages.at(-1)).toMatchObject({ kind: "action", revision: 1, payload: { action: "save" } });
  editor.destroy();
  Object.defineProperty(window, "webkit", { configurable: true, value: undefined });
});
