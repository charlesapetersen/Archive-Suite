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

    /// The in-flight basename search, if any. Cancelled on dismiss / re-show (W23.m14).
    private var searchTask: Task<Void, Never>?
    /// The view the current popover is anchored to, so a search that finishes later can
    /// still put its answer in the right place.
    private weak var anchorView: NSView?
    private let searchModel = PreviewSearchModel()

    init(resolver: ReaderLinkResolver) {
        self.resolver = resolver
    }

    /// Show a preview popover for the given source anchor, anchored to `view`.
    ///
    /// Returns as soon as the walk-free stage of resolution is done. If the exact path is
    /// missing, the basename search runs off the main actor and fills the popover in when
    /// it lands — clicking a broken link no longer freezes the UI (W23.m14).
    func show(for anchor: SourceAnchor, relativeTo view: NSView) {
        dismiss()
        anchorView = view

        guard let linkStr = anchor.link,
              let url = URL(string: linkStr),
              case .readerReveal(let guid, let rel, let page) = DurableLink(url: url) else {
            showMessage("No valid archive link.", relativeTo: view)
            return
        }

        switch resolver.resolveExact(rootGUID: guid, relativePath: rel) {
        case .decided(let resolution):
            present(resolution, page: page, relativeTo: view)
        case .needsBasenameSearch:
            let search = searchModel.beginSearch()
            showSearching(relativeTo: view)
            searchTask = Task { [weak self] in
                guard let self else { return }
                let resolution = await self.resolver.resolve(
                    rootGUID: guid,
                    relativePath: rel,
                    progress: { [weak self] scanned in
                        self?.searchModel.advance(to: scanned, generation: search)
                    }
                )
                // A cancelled search's answer is stale by construction — the popover was
                // dismissed or replaced, so it must not reopen one.
                guard !Task.isCancelled else { return }
                // The chip went away while we searched: take the "searching" popover with
                // it rather than leaving it up forever.
                guard let target = self.anchorView, target === view, target.window != nil else {
                    self.closePopover()
                    return
                }
                self.present(resolution, page: page, relativeTo: target)
            }
        }
    }

    func dismiss() {
        searchTask?.cancel()
        searchTask = nil
        closePopover()
        // The preview is what held the Reader root open, so the preview is what gives it back
        // (W26.notesabsence-fu3). `show` calls `dismiss` first, so a second preview of the SAME
        // root re-enters its scope a moment later — cheap, and it keeps this the only release site.
        resolver.releaseRootScope()
    }

    // MARK: - Private

    private func present(_ resolution: LinkResolution, page: Int?, relativeTo view: NSView) {
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
        case .searchIncomplete(let scanned):
            // Never report "not found" for a search that did not finish.
            //
            // Says *that* it did not finish, not *how* it stopped (W26.notesabsence). This read
            // "stopped after N items", which was true of the only two ways a search could end
            // early then — cancelled, or hitting its entry bound. It is now also reached by a walk
            // that ran all the way to the end and was DENIED part of the tree, where "stopped
            // after 3,412 items" is exactly the confident-sounding wrong sentence this wave exists
            // to stop an app saying. The count still earns its place — it is what the user watched
            // tick up — but as an amount examined, not as the point where the search gave up.
            showMessage(
                "Original file not found at its recorded path.\nThe search of the archive did not finish (\(scanned) items examined), so the file may still be there.",
                relativeTo: view
            )
        case .grantRefused(let refusal):
            // The chosen folder was not adopted. Saying so is the whole point of the case: the
            // silent version of this asked for the same folder again (W26.notesabsence-fu1).
            showMessage(refusal.message, relativeTo: view)
        }
    }

    private func showSearching(relativeTo anchor: NSView) {
        closePopover()
        let content = PreviewSearchingView(model: searchModel)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 300, height: 120)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: content)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popover = pop
    }

    /// Close the current popover WITHOUT cancelling the search — used when swapping the
    /// "searching" popover for its result.
    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
    }

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

/// Live entry count for an in-flight basename search (W23.m14).
///
/// Ticks are relayed from the scanning thread through the main actor, so they can land
/// out of order — and a finished search's stragglers can land after the next one starts.
/// The generation token drops those; the count itself only ever rises.
@MainActor
final class PreviewSearchModel: ObservableObject {
    @Published private(set) var scanned = 0
    private var generation = 0

    /// Start a new search: zero the readout, and return the token that scopes its ticks.
    func beginSearch() -> Int {
        generation += 1
        scanned = 0
        return generation
    }

    func advance(to count: Int, generation token: Int) {
        guard token == generation, count > scanned else { return }
        scanned = count
    }
}

private struct PreviewSearchingView: View {
    @ObservedObject var model: PreviewSearchModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.small)
            Text("Original file not found at its recorded path.\nSearching the archive\u{2026}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(model.scanned > 0 ? "\(model.scanned) items checked" : " ")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
        .padding(8)
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
