import { syntaxTree } from "@codemirror/language";
import { EditorState } from "@codemirror/state";

export interface TagObjectRange { from: number; to: number; }

export function locateMarkdownTagObject(state: EditorState, position: number, around: boolean): TagObjectRange | undefined {
  let node = syntaxTree(state).resolveInner(position, -1);
  while (node && node.name !== "Paragraph" && node.name !== "HTMLBlock") node = node.parent!;
  if (!node || (node.name !== "Paragraph" && node.name !== "HTMLBlock")) return undefined;
  const source = state.doc.sliceString(node.from, node.to);
  const tokens = [...source.matchAll(/<\/?[A-Za-z][A-Za-z0-9:-]*(?:\s+(?:"[^"]*"|'[^']*'|[^'">])*)?\s*\/?>/gu)];
  const stack: Array<{ name: string; start: number; openEnd: number }> = [];
  const pairs: Array<{ start: number; openEnd: number; closeStart: number; end: number }> = [];
  for (const token of tokens) {
    const raw = token[0], index = token.index;
    const name = /^<\/?([A-Za-z][A-Za-z0-9:-]*)/u.exec(raw)?.[1]?.toLowerCase();
    if (!name || /\/\s*>$/u.test(raw)) continue;
    if (raw.startsWith("</")) {
      for (let candidate = stack.length - 1; candidate >= 0; candidate -= 1) {
        if (stack[candidate]?.name !== name) continue;
        const opening = stack.splice(candidate, 1)[0]!;
        pairs.push({ start: opening.start, openEnd: opening.openEnd, closeStart: index, end: index + raw.length });
        break;
      }
    } else stack.push({ name, start: index, openEnd: index + raw.length });
  }
  const local = position - node.from;
  const match = pairs.filter(pair => local >= pair.openEnd && local <= pair.closeStart)
    .sort((left, right) => (left.end - left.start) - (right.end - right.start))[0];
  if (!match) return undefined;
  return around
    ? { from: node.from + match.start, to: node.from + match.end }
    : { from: node.from + match.openEnd, to: node.from + match.closeStart };
}
