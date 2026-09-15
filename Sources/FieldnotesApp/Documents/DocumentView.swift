import SwiftUI

struct DocumentView: View {
    let state: DocumentState

    var body: some View {
        VStack(spacing: 8) {
            Text("Markdown editor")
                .font(.headline)
            Text("\(state.editorText.utf16.count) characters")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
