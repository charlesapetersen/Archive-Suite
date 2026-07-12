import AppKit
import SwiftUI
import PDFKit
import ArchiveCore

/// Shows an NSPopover with a lightweight PDF preview for a source block's
/// archivereader:// link. Resolves the link via `ReaderLinkResolver`, then
/// displays the page (or a degrade message) using `NotesPDFPaneView`.
@MainActor
final class ReaderPreviewPopover {

    private var popover: NSPopover?
    private let resolver: ReaderLinkResolver

    init(resolver: ReaderLinkResolver) {
        self.resolver = resolver
    }

    /// Show a preview popover for the given source anchor, anchored to `view`.
    func show(for anchor: SourceAnchor, relativeTo view: NSView) {
        dismiss()

        guard let linkStr = anchor.link,
              let url = URL(string: linkStr),
              case .readerReveal(let guid, let rel, let page) = DurableLink(url: url) else {
            showMessage("No valid archive link.", relativeTo: view)
            return
        }

        let resolution = resolver.resolve(rootGUID: guid, relativePath: rel)
        switch resolution {
        case .resolved(let fileURL):
            showPDF(fileURL: fileURL, page: page, relativeTo: view)
        case .needsRootGrant:
            showMessage(
                "This link points to an archive not set up on this Mac.\nUse File \u{25b8} Choose Archive Folder\u{2026} in Reader first.",
                relativeTo: view
            )
        case .renamedCandidate(let candidate):
            showMessage(
                "Original file not found.\nA file with the same name exists at:\n\(candidate.lastPathComponent)",
                relativeTo: view
            )
        case .notFound:
            showMessage("Source file not found in the archive.", relativeTo: view)
        }
    }

    func dismiss() {
        popover?.performClose(nil)
        popover = nil
    }

    // MARK: - Private

    private func showPDF(fileURL: URL, page: Int?, relativeTo anchorView: NSView) {
        guard let doc = PDFDocument(url: fileURL) else {
            showMessage("Could not open PDF.", relativeTo: anchorView)
            return
        }

        let pageIndex = (page ?? 1) - 1 // 1-based → 0-based
        let pdfPage = doc.page(at: max(0, pageIndex))

        let controller = NotesPDFPaneController()
        let content = PreviewContentView(page: pdfPage, controller: controller, fileName: fileURL.lastPathComponent)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 400, height: 500)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: content)
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        popover = pop
    }

    private func showMessage(_ text: String, relativeTo anchorView: NSView) {
        let content = PreviewMessageView(message: text)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 300, height: 100)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: content)
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        popover = pop
    }
}

// MARK: - SwiftUI content views

private struct PreviewContentView: View {
    let page: PDFPage?
    let controller: NotesPDFPaneController
    let fileName: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button { controller.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.borderless)
                Button { controller.fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                Button { controller.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.bar)
            Divider()
            NotesPDFPaneView(page: page, controller: controller)
        }
    }
}

private struct PreviewMessageView: View {
    let message: String

    var body: some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
            Spacer()
        }
    }
}

// MARK: - Environment bridge

/// ObservableObject holding the `ReaderPreviewPopover`, passed as `@EnvironmentObject`
/// so `NoteEditorPane` can wire the preview callback without directly depending on the resolver.
@MainActor
final class SourceBlockPreviewState: ObservableObject {
    private let rootStore: ReaderRootStore
    private let preview: ReaderPreviewPopover

    init() {
        let store = ReaderRootStore()
        self.rootStore = store
        let resolver = ReaderLinkResolver(rootStore: store)
        self.preview = ReaderPreviewPopover(resolver: resolver)
    }

    func show(for anchor: SourceAnchor, relativeTo view: NSView) {
        preview.show(for: anchor, relativeTo: view)
    }

    func dismiss() {
        preview.dismiss()
    }
}
