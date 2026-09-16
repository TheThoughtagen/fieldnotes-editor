import SwiftUI

struct DocumentView: View {
    let state: DocumentState
    let session: EditorSession
    var confirmConflict: (ConflictReview) throws -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let conflict = state.conflict {
                ConflictView(conflict: conflict, confirm: confirmConflict)
                    .id(conflict.id)
            }
            if let error = state.externalReadError {
                Text("External change: \(error)").font(.callout).padding(8)
            }
            WebEditorView(session: session, revision: state.revision)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(state: state, session: session)
        }
    }
}

private struct StatusBar: View {
    let state: DocumentState
    let session: EditorSession

    var body: some View {
        HStack(spacing: 14) {
            Text(session.vimMode == "off" ? "Vim off" : "Vim \(session.vimMode)")
            Text("Ln \(session.line), Col \(session.column)")
            Text("\(session.wordCount) words")
            Text(session.schemaStatus.rawValue)
            Spacer()
            Text(state.conflict != nil ? "External conflict" : state.hasUnsavedText ? "Edited" : "Saved")
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}
