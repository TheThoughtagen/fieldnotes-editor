import SwiftUI

struct ConflictView: View {
    let conflict: ConflictModel
    let confirm: (ConflictReview) throws -> Void
    @State private var expanded = false
    @State private var review: ConflictReview?
    @State private var merged = ""
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(conflict.theirs == nil ? "This file was deleted outside Fieldnotes." : "This file changed outside Fieldnotes.")
                Spacer()
                Button(expanded ? "Hide comparison" : "Compare versions") {
                    expanded.toggle()
                    if review == nil { review = ConflictReview(conflict: conflict); merged = conflict.ours }
                }
            }
            if expanded {
                HStack(alignment: .top) {
                    version("Last saved", String(decoding: conflict.base, as: UTF8.self))
                    version("Editor", conflict.ours)
                    version("Disk", conflict.theirs.map { String(decoding: $0, as: UTF8.self) } ?? "File deleted")
                }.frame(height: 140)
                Text("Merge result").font(.caption)
                TextEditor(text: $merged).font(.system(.body, design: .monospaced)).frame(height: 90)
                HStack {
                    Button(conflict.theirs == nil ? "Keep editor for recreation…" : "Keep editor…") { choose(.editor) }
                    Button("Use disk…") { choose(.disk) }.disabled(conflict.theirs == nil)
                    Button("Use merge result…") { choose(.merged(merged)) }
                }
                Text("Choosing a version changes the editor only. Save writes it to disk.").font(.caption)
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
        .alert("Confirm conflict resolution", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { review?.cancel() }
            Button("Use selected version", role: .destructive) {
                guard let review else { return }
                do { try confirm(review) } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("The editor will use your selection. The other versions will no longer be shown in this comparison. The disk file remains unchanged until you save.")
        }
    }

    private func choose(_ resolution: ConflictResolution) {
        review?.choose(resolution)
        confirming = true
    }

    private func version(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption.bold())
            ScrollView([.vertical, .horizontal]) {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity)
    }
}
