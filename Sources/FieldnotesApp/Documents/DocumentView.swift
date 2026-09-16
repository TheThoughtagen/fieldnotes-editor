import SwiftUI

struct DocumentView: View {
    let state: DocumentState
    let session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
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
            Text(state.editorText == state.baseText ? "Saved" : "Edited")
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 10)
        .frame(height: 28)
        .accessibilityElement(children: .combine)
    }
}
