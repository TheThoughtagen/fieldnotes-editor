import { StateEffect, Transaction } from "@codemirror/state";
import { EditorView, ViewUpdate } from "@codemirror/view";

interface Selection {
  anchor: number;
  head: number;
}

interface SnapshotReply {
  kind: "snapshot";
  documentID: string;
  revision: number;
  text: string;
  selection: Selection;
}

interface AckReply {
  kind: "ack";
  documentID: string;
  revision: number;
}

interface RejectedReply {
  kind: "rejected";
  reason: string;
}

export type NativeReply = SnapshotReply | AckReply | RejectedReply;

interface NativeHandler {
  postMessage(message: unknown): Promise<unknown>;
}

interface WebKitWindow extends Window {
  webkit?: { messageHandlers?: { native?: NativeHandler } };
}

interface PendingEdit {
  text: string;
  selection: Selection;
  editKind: "done" | "undone" | "redone";
}

export interface NativeBridge {
  readonly available: boolean;
  readonly ready: Promise<void>;
}

let activeApply: ((snapshot: unknown) => boolean) = () => false;

function installPublicAPI(): void {
  const api = Object.freeze({
    applyNativeSnapshot(snapshot: unknown): boolean {
      return activeApply(snapshot);
    },
  });
  Object.defineProperty(window, "fieldnotes", { configurable: true, enumerable: false, value: api, writable: false });
}

installPublicAPI();

export function createNativeBridge(view: EditorView): NativeBridge {
  const handler = (window as WebKitWindow).webkit?.messageHandlers?.native;
  let documentID = "";
  let revision = 0;
  let applyingNative = false;
  let inFlight = false;
  let pending: PendingEdit | undefined;

  const applySnapshot = (value: unknown): boolean => {
    const snapshot = validSnapshot(value);
    if (!snapshot) return false;
    if (documentID && snapshot.documentID !== documentID) return false;
    if (snapshot.revision < revision) return false;
    documentID = snapshot.documentID;
    if (snapshot.revision === revision && view.state.doc.toString() === snapshot.text) return true;
    applyingNative = true;
    try {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: snapshot.text },
        selection: { anchor: snapshot.selection.anchor, head: snapshot.selection.head },
      });
      revision = snapshot.revision;
      pending = undefined;
    } finally {
      applyingNative = false;
    }
    return true;
  };
  activeApply = applySnapshot;

  const handleReply = (value: unknown, expectedRevision?: number): void => {
    const reply = validReply(value);
    if (!reply) return;
    if (reply.kind === "snapshot") {
      applySnapshot(reply);
      return;
    }
    if (reply.kind === "ack" && reply.documentID === documentID && reply.revision === expectedRevision) {
      revision = reply.revision;
    }
  };

  const sendPending = (): void => {
    if (!handler || inFlight || !pending || !documentID) return;
    const edit = pending;
    pending = undefined;
    const expectedRevision = revision + 1;
    inFlight = true;
    void handler.postMessage({
      kind: "transaction",
      documentID,
      baseRevision: revision,
      revision: expectedRevision,
      payload: edit,
    }).then((reply) => handleReply(reply, expectedRevision)).finally(() => {
      inFlight = false;
      sendPending();
    });
  };

  const onUpdate = (update: ViewUpdate): void => {
    if (applyingNative || !handler || !documentID) return;
    const selection = {
      anchor: update.state.selection.main.anchor,
      head: update.state.selection.main.head,
    };
    if (update.docChanged) {
      pending = { text: update.state.doc.toString(), selection, editKind: transactionKind(update) };
      sendPending();
    } else if (update.selectionSet && !inFlight) {
      void handler.postMessage({
        kind: "selection",
        documentID,
        baseRevision: revision,
        revision,
        payload: { selection },
      }).then((reply) => handleReply(reply, revision));
    }
  };
  view.dispatch({ effects: StateEffect.appendConfig.of(EditorView.updateListener.of(onUpdate)) });

  const ready = handler
    ? handler.postMessage({ kind: "ready", documentID: "", baseRevision: 0, revision: 0, payload: {} })
      .then((reply) => { applySnapshot(reply); })
    : Promise.resolve();

  return { available: Boolean(handler), ready };
}

function transactionKind(update: ViewUpdate): PendingEdit["editKind"] {
  if (update.transactions.some((transaction) => transaction.isUserEvent("undo"))) return "undone";
  if (update.transactions.some((transaction) => transaction.isUserEvent("redo"))) return "redone";
  return "done";
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

function validSelection(value: unknown): value is Selection {
  return isRecord(value) && Object.keys(value).length === 2 && isInteger(value.anchor) && isInteger(value.head);
}

function validSnapshot(value: unknown): SnapshotReply | undefined {
  if (!isRecord(value) || Object.keys(value).length !== 5) return undefined;
  if (value.kind !== "snapshot" || typeof value.documentID !== "string" || !value.documentID || !isInteger(value.revision) || typeof value.text !== "string" || !validSelection(value.selection)) return undefined;
  if (value.selection.anchor > value.text.length || value.selection.head > value.text.length) return undefined;
  return value as unknown as SnapshotReply;
}

function validReply(value: unknown): NativeReply | undefined {
  const snapshot = validSnapshot(value);
  if (snapshot) return snapshot;
  if (!isRecord(value)) return undefined;
  if (Object.keys(value).length === 3 && value.kind === "ack" && typeof value.documentID === "string" && isInteger(value.revision)) return value as unknown as AckReply;
  if (Object.keys(value).length === 2 && value.kind === "rejected" && typeof value.reason === "string") return value as unknown as RejectedReply;
  return undefined;
}

declare global {
  interface Window {
    fieldnotes: {
      applyNativeSnapshot(snapshot: unknown): boolean;
    };
  }
}
