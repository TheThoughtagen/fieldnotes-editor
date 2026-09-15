import { Compartment, EditorState, StateEffect } from "@codemirror/state";
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

interface InFlightEdit {
  expectedRevision: number;
  edit: PendingEdit;
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
  let authoritativeText = "";
  let hasSnapshot = false;
  let applyingNative = false;
  let inFlight: InFlightEdit | undefined;
  let pending: PendingEdit | undefined;
  const readyGate = new Compartment();

  const applySelection = (selection: Selection): void => {
    if (selection.anchor > view.state.doc.length || selection.head > view.state.doc.length) return;
    if (view.state.selection.main.anchor === selection.anchor && view.state.selection.main.head === selection.head) return;
    applyingNative = true;
    try {
      view.dispatch({ selection });
    } finally {
      applyingNative = false;
    }
  };

  const applyExactSnapshot = (snapshot: SnapshotReply): void => {
    applyingNative = true;
    try {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: snapshot.text },
        selection: snapshot.selection,
      });
    } finally {
      applyingNative = false;
    }
  };

  const applySnapshot = (value: unknown): boolean => {
    const snapshot = validSnapshot(value);
    if (!snapshot) return false;
    if (documentID && snapshot.documentID !== documentID) return false;
    if (snapshot.revision < revision) return false;

    if (hasSnapshot && snapshot.revision === revision) {
      if (snapshot.text !== authoritativeText) return false;
      if (view.state.doc.toString() === authoritativeText) applySelection(snapshot.selection);
      return true;
    }

    if (hasSnapshot && inFlight && snapshot.revision === inFlight.expectedRevision && snapshot.text === inFlight.edit.text) {
      documentID = snapshot.documentID;
      revision = snapshot.revision;
      authoritativeText = snapshot.text;
      inFlight = undefined;
      if (!pending && view.state.doc.toString() === authoritativeText) applySelection(snapshot.selection);
      sendPending();
      return true;
    }

    documentID = snapshot.documentID;
    revision = snapshot.revision;
    authoritativeText = snapshot.text;
    hasSnapshot = true;
    pending = undefined;
    inFlight = undefined;
    applyExactSnapshot(snapshot);
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
    if (reply.kind === "ack" && reply.documentID === documentID && reply.revision === expectedRevision && inFlight?.expectedRevision === expectedRevision) {
      if (reply.revision > revision) {
        revision = reply.revision;
        authoritativeText = inFlight.edit.text;
      }
      inFlight = undefined;
      sendPending();
    }
  };

  const sendPending = (): void => {
    if (!handler || inFlight || !pending || !documentID || !hasSnapshot) return;
    const edit = pending;
    pending = undefined;
    const expectedRevision = revision + 1;
    inFlight = { expectedRevision, edit };
    void handler.postMessage({
      kind: "transaction",
      documentID,
      baseRevision: revision,
      revision: expectedRevision,
      payload: edit,
    }).then((reply) => handleReply(reply, expectedRevision));
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
  view.dispatch({ effects: StateEffect.appendConfig.of([
    readyGate.of([
      EditorState.readOnly.of(Boolean(handler)),
      EditorView.editable.of(!handler),
    ]),
    EditorView.updateListener.of(onUpdate),
  ]) });

  const ready = handler
    ? handler.postMessage({ kind: "ready", documentID: "", baseRevision: 0, revision: 0, payload: {} })
      .then((reply) => {
        if (!applySnapshot(reply)) return;
        view.dispatch({ effects: readyGate.reconfigure([
          EditorState.readOnly.of(false),
          EditorView.editable.of(true),
        ]) });
      })
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
