const editorRoot = document.querySelector<HTMLElement>("#editor");

if (!editorRoot) {
  throw new Error("FIELDNOTES requires one #editor root");
}

editorRoot.dataset.booted = "true";
editorRoot.setAttribute("role", "application");

export {};
