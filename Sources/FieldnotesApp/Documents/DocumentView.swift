import SwiftUI

struct DocumentView: View {
    let state: DocumentState
    let session: EditorSession

    var body: some View {
        WebEditorView(session: session, revision: state.revision)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
