import { Compartment, EditorState, StateEffect } from "@codemirror/state";
import { EditorView, ViewUpdate } from "@codemirror/view";

interface Selection {
  anchor: number;
  head: number;
}

export interface OpenContext {
  generation: number; workspaceName: string; documentName: string | null;
  assetPolicy: "workspace" | "document-directory";
  mode: "focus" | "source" | "preview" | null;
  line: number | null; column: number | null;
  diagnostics: string[]; schema: Record<string, unknown> | null;
}

interface SnapshotReply {
  kind: "snapshot";
  openContext?: OpenContext;
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

type BridgeState = "standalone" | "connecting" | "ready" | "recovering" | "disconnected";

export interface NativeBridge {
  readonly available: boolean;
  readonly ready: Promise<void>;
  readonly contextGeneration: number;
  searchFiles(query: string, includeContent?: boolean): Promise<{ id: string; title: string }[]>;
  openFile(id: string): Promise<void>;
  postStatus(status: EditorStatus): void;
  postSchemaState(state: "none" | "valid" | "invalid"): void;
  requestAction(action: "save" | "quit"): Promise<boolean>;
  destroy(): void;
}

export interface EditorStatus {
  presentationMode: "focus" | "source" | "preview";
  vimMode: string;
  line: number;
  column: number;
  wordCount: number;
}

let activeApply: ((snapshot: unknown) => boolean) = () => false;

function installPublicAPI(): void {
  const api = Object.freeze({
    applyNativeSnapshot(snapshot: unknown): boolean {
      return activeApply(snapshot);
    },
    setMode: (_mode: unknown) => false,
    cycleMode: () => undefined,
    setVimEnabled: (_enabled: unknown) => false,
    toggleVim: () => undefined,
    destroy: () => undefined,
  });
  Object.defineProperty(window, "fieldnotes", { configurable: true, enumerable: false, value: api, writable: false });
}

installPublicAPI();

export function createNativeBridge(view: EditorView, onContext?: (context: OpenContext) => void): NativeBridge {
  let contextGeneration = 0;
  const handler = (window as WebKitWindow).webkit?.messageHandlers?.native;
  let documentID = "";
  let revision = 0;
  let authoritativeText = "";
  let hasSnapshot = false;
  let applyingNative = false;
  let inFlight: InFlightEdit | undefined;
  let pending: PendingEdit | undefined;
  let recoveryAttempted = false;
  let bridgeState: BridgeState = handler ? "connecting" : "standalone";
  let destroyed = false;
  let statusTimer: number | undefined;
  let statusPending: EditorStatus | undefined;
  const readyGate = new Compartment();

  const setBridgeState = (state: BridgeState): void => {
    bridgeState = state;
    view.dom.dataset.bridgeState = state;
    const editable = state === "ready" || state === "recovering" || state === "standalone";
    view.contentDOM.setAttribute("aria-disabled", String(!editable));
    view.dispatch({ effects: readyGate.reconfigure([
      EditorState.readOnly.of(!editable),
      EditorView.editable.of(editable),
    ]) });
  };

  const safePost = (message: unknown): Promise<unknown> => Promise.resolve().then(() => destroyed ? undefined : handler?.postMessage(message));

  function flushStatus(): void {
    if (!handler || destroyed || !documentID || inFlight || pending || bridgeState !== "ready" || !statusPending) return;
    const status = statusPending;
    statusPending = undefined;
    void safePost({ kind: "status", documentID, baseRevision: revision, revision, payload: status });
  }

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

  const applySnapshotContent = (value: unknown): boolean => {
    if (bridgeState === "disconnected" || bridgeState === "recovering") return false;
    const snapshot = validSnapshot(value);
    if (!snapshot) return false;
    if (documentID && snapshot.documentID !== documentID) return false;
    if (snapshot.revision < revision) return false;

    if (hasSnapshot && snapshot.revision === revision) {
      if (snapshot.text !== authoritativeText) return false;
      // Context replay acknowledges delivery; it does not restore an older cursor.
      if (snapshot.openContext && snapshot.openContext.generation <= contextGeneration && !inFlight) return true;
      if (inFlight?.edit.text === authoritativeText) {
        inFlight = undefined;
        recoveryAttempted = false;
        if (!pending && view.state.doc.toString() === authoritativeText) applySelection(snapshot.selection);
        sendPending();
        flushStatus();
        return true;
      }
      if (view.state.doc.toString() === authoritativeText) applySelection(snapshot.selection);
      return true;
    }

    if (hasSnapshot && inFlight && snapshot.revision === inFlight.expectedRevision && snapshot.text === inFlight.edit.text) {
      documentID = snapshot.documentID;
      revision = snapshot.revision;
      authoritativeText = snapshot.text;
      inFlight = undefined;
      recoveryAttempted = false;
      if (!pending && view.state.doc.toString() === authoritativeText) applySelection(snapshot.selection);
      sendPending();
      flushStatus();
      return true;
    }

    documentID = snapshot.documentID;
    revision = snapshot.revision;
    authoritativeText = snapshot.text;
    hasSnapshot = true;
    pending = undefined;
    inFlight = undefined;
    recoveryAttempted = false;
    applyExactSnapshot(snapshot);
    return true;
  };
  const applyContext = (snapshot: SnapshotReply): void => {
    const context = snapshot.openContext;
    if (!context || context.generation < contextGeneration) return;
    if (context.generation > contextGeneration) {
      statusPending = undefined;
      contextGeneration = context.generation;
      onContext?.(context);
    }
    void safePost({ kind: "contextApplied", documentID, baseRevision: revision, revision, payload: { generation: contextGeneration } }).catch(() => undefined);
  };
  const applySnapshot = (value: unknown): boolean => {
    if (!applySnapshotContent(value)) return false;
    applyContext(value as SnapshotReply);
    return true;
  };
  activeApply = applySnapshot;

  const disconnect = (): void => {
    inFlight = undefined;
    bridgeState = "disconnected";
    view.dom.dataset.bridgeState = "disconnected";
    view.contentDOM.setAttribute("aria-disabled", "true");
    view.dispatch({ effects: readyGate.reconfigure([
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
    ]) });
  };

  const latestEdit = (): PendingEdit => ({
    text: view.state.doc.toString(),
    selection: {
      anchor: view.state.selection.main.anchor,
      head: view.state.selection.main.head,
    },
    editKind: "done",
  });

  const beginRecovery = (): void => {
    if (!handler || bridgeState === "disconnected" || bridgeState === "recovering" || !documentID || !hasSnapshot || recoveryAttempted) {
      disconnect();
      return;
    }
    recoveryAttempted = true;
    const hadUnresolvedIntent = Boolean(inFlight || pending);
    const latest = latestEdit();
    pending = hadUnresolvedIntent || latest.text !== authoritativeText ? latest : undefined;
    inFlight = undefined;
    setBridgeState("recovering");
    const requestedRevision = revision;
    void safePost({
      kind: "requestSnapshot",
      documentID,
      baseRevision: requestedRevision,
      revision: requestedRevision,
      payload: {},
    }).then((value) => {
      if (bridgeState !== "recovering") return;
      const snapshot = validSnapshot(value);
      if (!snapshot || snapshot.documentID !== documentID || snapshot.revision < revision) {
        disconnect();
        return;
      }
      const localText = view.state.doc.toString();
      const localDiverges = Boolean(pending) || localText !== authoritativeText;
      revision = snapshot.revision;
      authoritativeText = snapshot.text;
      hasSnapshot = true;
      if (!localDiverges) {
        applyExactSnapshot(snapshot);
      } else if (localText === snapshot.text) {
        if (!pending) applySelection(snapshot.selection);
      }
      if (!pending) recoveryAttempted = false;
      setBridgeState("ready");
      applyContext(snapshot);
      sendPending();
      flushStatus();
    }).catch(() => disconnect());
  };

  const handleTransactionReply = (value: unknown, flight: InFlightEdit): void => {
    if (bridgeState === "disconnected" || inFlight !== flight) return;
    const reply = validReply(value);
    if (!reply || reply.kind === "rejected") {
      beginRecovery();
      return;
    }
    if (reply.kind === "snapshot") {
      if (!applySnapshot(reply) || inFlight === flight) beginRecovery();
      return;
    }
    if (reply.documentID === documentID && reply.revision === flight.expectedRevision) {
      if (reply.revision > revision) {
        revision = reply.revision;
        authoritativeText = flight.edit.text;
      }
      inFlight = undefined;
      recoveryAttempted = false;
      sendPending();
      flushStatus();
      return;
    }
    beginRecovery();
  };

  const sendPending = (): void => {
    if (!handler || inFlight || !pending || !documentID || !hasSnapshot || bridgeState !== "ready") return;
    const edit = pending;
    if (edit.text === authoritativeText) {
      pending = undefined;
      recoveryAttempted = false;
      sendSelection(edit.selection);
      return;
    }
    pending = undefined;
    const expectedRevision = revision + 1;
    const flight = { expectedRevision, edit };
    inFlight = flight;
    void safePost({
      kind: "transaction",
      documentID,
      baseRevision: revision,
      revision: expectedRevision,
      payload: edit,
    }).then((reply) => handleTransactionReply(reply, flight)).catch(() => {
      if (inFlight === flight) beginRecovery();
    });
  };

  const sendSelection = (selection: Selection): void => {
    if (!handler || !documentID || bridgeState !== "ready" || inFlight) return;
    const expectedRevision = revision;
    void safePost({
      kind: "selection",
      documentID,
      baseRevision: expectedRevision,
      revision: expectedRevision,
      payload: { selection },
    }).then((value) => {
      if (bridgeState === "disconnected" || revision !== expectedRevision) return;
      const reply = validReply(value);
      if (!reply || reply.kind === "rejected") {
        beginRecovery();
      } else if (reply.kind === "snapshot") {
        if (!applySnapshot(reply)) beginRecovery();
      } else if (reply.documentID !== documentID || reply.revision !== expectedRevision) {
        beginRecovery();
      }
    }).catch(() => beginRecovery());
  };

  const onUpdate = (update: ViewUpdate): void => {
    if (destroyed || applyingNative || !handler || !documentID) return;
    const selection = {
      anchor: update.state.selection.main.anchor,
      head: update.state.selection.main.head,
    };
    if (update.docChanged) {
      const text = update.state.doc.toString();
      if (!inFlight && hasSnapshot && text === authoritativeText) {
        pending = undefined;
        sendSelection(selection);
        return;
      }
      pending = { text, selection, editKind: transactionKind(update) };
      sendPending();
    } else if (update.selectionSet && !inFlight) {
      sendSelection(selection);
    }
  };
  view.dispatch({ effects: StateEffect.appendConfig.of([
    readyGate.of([
      EditorState.readOnly.of(Boolean(handler)),
      EditorView.editable.of(!handler),
    ]),
    EditorView.updateListener.of(onUpdate),
  ]) });
  view.dom.dataset.bridgeState = bridgeState;
  view.contentDOM.setAttribute("aria-disabled", String(Boolean(handler)));

  const ready = handler
    ? safePost({ kind: "ready", documentID: "", baseRevision: 0, revision: 0, payload: {} })
      .then((reply) => {
        if (!applySnapshot(reply)) {
          disconnect();
          return;
        }
        setBridgeState("ready");
        if (contextGeneration) sendSelection(latestEdit().selection);
      }).catch(() => disconnect())
    : Promise.resolve();

  const postStatus = (status: EditorStatus): void => {
    if (!handler || destroyed) return;
    statusPending = status;
    if (statusTimer !== undefined) window.clearTimeout(statusTimer);
    statusTimer = window.setTimeout(() => {
      statusTimer = undefined;
      flushStatus();
    }, 20);
  };

  const waitUntilIdle = async (): Promise<boolean> => {
    for (let attempt = 0; attempt < 200; attempt += 1) {
      if (destroyed || bridgeState === "disconnected") return false;
      if (!inFlight && !pending && (bridgeState === "ready" || bridgeState === "standalone")) return true;
      await new Promise(resolve => window.setTimeout(resolve, 5));
    }
    return false;
  };

  const requestAction = async (action: "save" | "quit"): Promise<boolean> => {
    if (!handler || !(await waitUntilIdle()) || !documentID) return false;
    const reply = validReply(await safePost({ kind: "action", documentID, baseRevision: revision, revision, payload: { action } }));
    return reply?.kind === "ack" && reply.documentID === documentID && reply.revision === revision;
  };

  const destroy = (): void => {
    destroyed = true;
    statusPending = undefined;
    if (statusTimer !== undefined) window.clearTimeout(statusTimer);
    if (activeApply === applySnapshot) activeApply = () => false;
  };

  const postSchemaState = (schemaState: "none" | "valid" | "invalid"): void => {
    if (!handler || !contextGeneration || destroyed) return;
    void safePost({ kind: "schemaStatus", documentID, baseRevision: revision, revision, payload: { generation: contextGeneration, schemaState } }).catch(() => undefined);
  };
  const searchFiles = async (query: string, includeContent = false): Promise<{ id: string; title: string }[]> => {
    if (!contextGeneration || !(await waitUntilIdle())) return [];
    const generation = contextGeneration;
    const reply = await safePost({ kind: "workspaceSearch", documentID, baseRevision: revision, revision, payload: { query: query.slice(0, 64), generation, includeContent } });
    if (!isRecord(reply) || reply.kind !== "workspaceResults" || reply.documentID !== documentID || reply.generation !== generation || generation !== contextGeneration || !Array.isArray(reply.results)) return [];
    return reply.results.filter((item): item is { id: string; title: string } => isRecord(item) && typeof item.id === "string" && /^[0-9a-f-]{36}$/i.test(item.id) && typeof item.title === "string");
  };
  const openFile = async (id: string): Promise<void> => {
    if (!contextGeneration || !(await waitUntilIdle())) return;
    await safePost({ kind: "workspaceOpen", documentID, baseRevision: revision, revision, payload: { resultID: id, generation: contextGeneration } });
  };
  return { available: Boolean(handler), ready, get contextGeneration() { return contextGeneration; }, searchFiles, openFile, postStatus, postSchemaState, requestAction, destroy };
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

function validContext(value: unknown): value is OpenContext {
  if (!isRecord(value) || Object.keys(value).length !== 9) return false;
  return isInteger(value.generation) && (value.generation as number) > 0 && typeof value.workspaceName === "string"
    && (value.documentName === null || typeof value.documentName === "string")
    && ["workspace", "document-directory"].includes(value.assetPolicy as string)
    && [null, "focus", "source", "preview"].includes(value.mode as string | null)
    && (value.line === null || (isInteger(value.line) && (value.line as number) > 0))
    && (value.column === null || (isInteger(value.column) && (value.column as number) > 0))
    && Array.isArray(value.diagnostics) && value.diagnostics.every(item => typeof item === "string")
    && (value.schema === null || isRecord(value.schema));
}

function validSnapshot(value: unknown): SnapshotReply | undefined {
  if (!isRecord(value) || Object.keys(value).some(key => !["kind", "documentID", "revision", "text", "selection", "openContext"].includes(key))) return undefined;
  if (value.openContext !== undefined && !validContext(value.openContext)) return undefined;
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
      setMode(mode: unknown): boolean;
      cycleMode(): void;
      setVimEnabled(enabled: unknown): boolean;
      toggleVim(): void;
      destroy(): void;
    };
  }
}
