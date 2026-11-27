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
    let usesCatalogue: Bool
    let physicalPageIndex: Int?
    var isVisible = true
    var onClose: () -> Void

    init(model: NavigationModel, paths: [String], identity: String? = nil, isVisible: Bool = true,
         physicalPageIndex: Int? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.paths = paths
        self.identity = identity ?? paths.sorted().joined(separator: "\n")
        self.usesCatalogue = model.library.usesCatalogue
        self.physicalPageIndex = physicalPageIndex
        self.isVisible = isVisible
        self.onClose = onClose
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.identity == b.identity && a.isVisible == b.isVisible && a.model === b.model
            && a.usesCatalogue == b.usesCatalogue && a.physicalPageIndex == b.physicalPageIndex
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
            } else if usesCatalogue {
                CatalogueInspectorView(model: model, paths: paths, physicalPageIndex: physicalPageIndex,
                                       isVisible: isVisible, onClose: onClose)
                    .id(identity)
            } else {
                TagEditorView(model: model, targetPaths: paths, isVisible: isVisible, onClose: onClose)
                    .id(identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .environment(\.inspectorShown, isVisible)
    }
}

extension EnvironmentValues {
    /// False inside an inspector that is kept mounted but hidden (`TagInspectorView.isVisible`).
    @Entry var inspectorShown = true
}

extension View {
    /// Takes an inspector's selectable text out of the window while its inspector is hidden
    /// (W49.reader-audit-preview-thumbs-viewer-orphan). The hidden inspector is kept mounted at zero width so a draft
    /// survives ⌥⌘I, but `accessibilityHidden` on it does not reach text with `.textSelection(.enabled)`, which
    /// macOS draws with an AppKit view: it stayed in the window's accessibility tree under a parent that no longer
    /// listed it, the audit's "Parent/Child mismatch" naming no element (probed in the guest: it went with the
    /// item-field rows hidden, or their value not selectable). `hidden()` removes it. Apply it only to views that
    /// keep no draft: the if/else rebuilds the view when the inspector is shown again.
    func hiddenWithInspector() -> some View { modifier(HiddenWithInspector()) }
}

private struct HiddenWithInspector: ViewModifier {
    @Environment(\.inspectorShown) private var shown

    func body(content: Content) -> some View {
        if shown { content } else { content.hidden() }
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
