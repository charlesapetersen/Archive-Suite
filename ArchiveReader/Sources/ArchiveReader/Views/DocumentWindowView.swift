import SwiftUI

/// The document-view window. Scaffolding for now.
/// M2 adds: the two-up viewer (image left / OCR text right), independent per-pane zoom, a draggable
/// gray splitter (default ⅔ : ⅓), ↑/↓ cycling through the selection, intelligent copy, and in-doc Find.
struct DocumentWindowView: View {
    let selection: DocumentSelection?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.image")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Document View")
                .font(.title.bold())
            if let selection, !selection.filePaths.isEmpty {
                Text("^[\(selection.filePaths.count) document](inflect: true) selected")
                    .foregroundStyle(.secondary)
            } else {
                Text("Two-up viewer — foundation scaffold.")
                    .foregroundStyle(.secondary)
                Text("Image page left / OCR text page right arrives in M2.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .padding(40)
    }
}

#Preview {
    DocumentWindowView(selection: DocumentSelection(filePaths: []))
}
