import Combine
import SwiftUI

/// Each selection gets its own editor state and immutable target paths. A field leaving focus during
/// a selection change can only commit to the files it was typed for, never to the new selection.
///
/// It does not observe the model (W40.fix-reader-selection-at-size). It is redrawn when its `identity` or
/// visibility changes (`Equatable`), and its editor follows the model through an `InspectorFeed` only while it
/// is shown, so a hidden inspector, in the library window or in each document window, costs nothing per publish.
struct TagInspectorView: View, Equatable {
    let model: NavigationModel
    let paths: [String]
    /// Changes exactly when `paths` names other files: the library window passes its `inspectorTarget`'s
    /// generation, a document window its open file's path.
    let identity: String
    var isVisible = true
    var onClose: () -> Void

    init(model: NavigationModel, paths: [String], identity: String? = nil, isVisible: Bool = true,
         onClose: @escaping () -> Void) {
        self.model = model
        self.paths = paths
        self.identity = identity ?? paths.sorted().joined(separator: "\n")
        self.isVisible = isVisible
        self.onClose = onClose
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.identity == b.identity && a.isVisible == b.isVisible && a.model === b.model
    }

    var body: some View {
        Group {
            if paths.isEmpty {
                VStack(spacing: 16) {
                    HStack {
                        Text("Inspector").font(.headline)
                        Spacer()
                        Button("Close", action: onClose).accessibilityIdentifier("ar.tagEditor.done")
                    }
                    Text("Select a file or group to edit its info.").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                TagEditorView(model: model, targetPaths: paths, isVisible: isVisible, onClose: onClose)
                    .id(identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

/// The model's changes, passed on to a shown inspector only. A hidden one hears nothing, and catches up with
/// one change when it is shown again.
@MainActor
final class InspectorFeed: ObservableObject {
    private var subscription: AnyCancellable?
    private weak var followed: NavigationModel?

    func follow(_ model: NavigationModel, visible: Bool) {
        guard visible else { subscription = nil; followed = nil; return }
        guard subscription == nil || followed !== model else { return }
        followed = model
        subscription = model.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        objectWillChange.send()
    }
}
