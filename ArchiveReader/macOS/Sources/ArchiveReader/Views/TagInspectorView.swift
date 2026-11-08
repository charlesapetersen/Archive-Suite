import SwiftUI

/// Each selection gets its own editor state and immutable target paths. A field leaving focus during
/// a selection change can only commit to the files it was typed for, never to the new selection.
struct TagInspectorView: View {
    @ObservedObject var model: NavigationModel
    let paths: [String]
    var isVisible = true
    var onClose: () -> Void

    var body: some View {
        Group {
            if paths.isEmpty {
                VStack(spacing: 16) {
                    HStack {
                        Text("Edit Info").font(.headline)
                        Spacer()
                        Button("Close", action: onClose).accessibilityIdentifier("ar.tagEditor.done")
                    }
                    Text("Select a file or group to edit its info.").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                TagEditorView(model: model, targetPaths: paths, isVisible: isVisible, onClose: onClose)
                    .id(paths.sorted())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}
