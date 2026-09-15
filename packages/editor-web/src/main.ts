import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { bracketMatching, defaultHighlightStyle, indentOnInput, syntaxHighlighting } from "@codemirror/language";
import { lintKeymap } from "@codemirror/lint";
import { highlightSelectionMatches, searchKeymap } from "@codemirror/search";
import { EditorState } from "@codemirror/state";
import {
  drawSelection,
  dropCursor,
  EditorView,
  highlightActiveLine,
  highlightSpecialChars,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { vim } from "@replit/codemirror-vim";

interface FieldnotesRoot extends HTMLElement {
  fieldnotesEditorView?: EditorView;
}

export function bootEditor(root: HTMLElement): EditorView {
  const editorRoot = root as FieldnotesRoot;
  editorRoot.fieldnotesEditorView?.destroy();
  editorRoot.replaceChildren();
  editorRoot.dataset.booted = "true";
  editorRoot.setAttribute("role", "application");

  const state = EditorState.create({
    doc: "# FIELDNOTES\n\n",
    extensions: [
      // Vim must precede other keymaps so normal-mode commands win precedence.
      vim(),
      lineNumbers(),
      highlightSpecialChars(),
      history(),
      drawSelection(),
      dropCursor(),
      indentOnInput(),
      bracketMatching(),
      closeBrackets(),
      autocompletion(),
      highlightActiveLine(),
      highlightSelectionMatches(),
      markdown(),
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      keymap.of([
        ...closeBracketsKeymap,
        ...defaultKeymap,
        ...searchKeymap,
        ...historyKeymap,
        ...completionKeymap,
        ...lintKeymap,
        indentWithTab,
      ]),
      EditorView.contentAttributes.of({ "aria-label": "Markdown source" }),
      EditorView.lineWrapping,
      EditorView.theme({
        "&": { height: "100%" },
        ".cm-scroller": { overflow: "auto" },
      }),
    ],
  });

  const view = new EditorView({ state, parent: editorRoot });
  editorRoot.fieldnotesEditorView = view;
  return view;
}

const editorRoot = document.querySelector<HTMLElement>("#editor");
if (!editorRoot) {
  throw new Error("FIELDNOTES requires one #editor root");
}

bootEditor(editorRoot);
