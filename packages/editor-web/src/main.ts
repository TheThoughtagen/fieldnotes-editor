import { createEditor, EditorController } from "./editor.js";

interface FieldnotesRoot extends HTMLElement { fieldnotesEditor?: EditorController; }

export function bootEditor(root: HTMLElement): EditorController["view"] {
  const editorRoot = root as FieldnotesRoot;
  editorRoot.fieldnotesEditor?.destroy();
  editorRoot.fieldnotesEditor = createEditor(root);
  return editorRoot.fieldnotesEditor.view;
}

const editorRoot = document.querySelector<HTMLElement>("#editor");
if (!editorRoot) throw new Error("FIELDNOTES requires one #editor root");
bootEditor(editorRoot);
