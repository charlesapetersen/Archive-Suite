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
    private let chooser: ReaderRootChooser

    /// The in-flight basename search, if any. Cancelled on dismiss / re-show (W23.m14).
    private var searchTask: Task<Void, Never>?
    /// The view the current popover is anchored to, so a search that finishes later can
    /// still put its answer in the right place.
    private weak var anchorView: NSView?
    private let searchModel = PreviewSearchModel()

    /// What the popover currently on screen is a preview *of*.
    ///
    /// Kept because the answer to a missing root — "choose the folder" — has to grant and then
    /// resolve *this* link, and the button that does it is built after `show` has finished parsing
    /// (W26.notesabsence-fu2).
    private struct LinkContext {
        let guid: UUID
        let relativePath: String
        let page: Int?
    }
    private var currentLink: LinkContext?

    init(resolver: ReaderLinkResolver, chooser: ReaderRootChooser) {
        self.resolver = resolver
        self.chooser = chooser
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
            currentLink = nil
            showMessage("No valid archive link.", relativeTo: view)
            return
        }
        currentLink = LinkContext(guid: guid, relativePath: rel, page: page)

        switch resolver.resolveExact(rootGUID: guid, relativePath: rel) {
        case .decided(let resolution):
            present(resolution, page: page, relativeTo: view)
        case .needsBasenameSearch:
            let search = searchModel.beginSearch()
            showSearching("Original file not found at its recorded path.\nSearching the archive\u{2026}",
                          relativeTo: view)
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
            // The old wording — "Use File ▸ Choose Archive Folder… in Reader first" — asked for
            // something that cannot work and could not be done anyway (W26.notesabsence-fu2).
            // Notes is sandboxed, so a folder the user grants to *Reader* conveys no access to
            // *Notes*; and until this item, Notes had no chooser of its own to send them to. Both
            // halves are fixed here: the sentence names Notes' own menu item, and the button does
            // it without leaving the popover.
            showMessage(
                "Archive Notes has not been given access to this archive folder.\n"
                    + "Granting it in Reader is not enough \u{2014} choose the same folder here.",
                relativeTo: view,
                actionTitle: "Choose Archive Folder\u{2026}",
                action: grantAction(fallbackTo: resolution, relativeTo: view)
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
                "Original file not found at its recorded path.\n"
                    + "The search of the archive did not finish (\(scanned) items examined), "
                    + "so the file may still be there.",
                relativeTo: view
            )
        case .grantRefused(let refusal):
            // The chosen folder was not adopted. Saying so is the whole point of the case: the
            // silent version of this asked for the same folder again (W26.notesabsence-fu1).
            showMessage(refusal.message, relativeTo: view,
                        actionTitle: "Choose Another Folder\u{2026}",
                        action: grantAction(fallbackTo: resolution, relativeTo: view))
        case .wrongArchive(let picked, _, _):
            // The grant STOOD — that archive is usable in Notes now — it just is not this link's.
            // Repeating "choose the folder" here would be telling them to do what they just did.
            showMessage(
                "“\(picked.lastPathComponent)” is a different archive.\n"
                    + "This source came from another archive folder \u{2014} choose that one to preview it.",
                relativeTo: view,
                actionTitle: "Choose Another Folder\u{2026}",
                action: grantAction(fallbackTo: resolution, relativeTo: view)
            )
        }
    }

    /// The action behind every "choose a folder" button: ask, grant, and re-resolve **this** link.
    ///
    /// `nil` when there is no link in hand (a malformed chip), so the button is simply absent
    /// rather than present and inert.
    ///
    /// - Parameter fallback: what to re-present if the panel is cancelled. A cancel is not a new
    ///   answer — the "Opening the archive…" spinner this puts up while the panel is open has
    ///   nothing to settle into otherwise, and would sit there forever: the panel dismisses the
    ///   popover on its way up (it is `.transient`), so once it closes there is no popover left to
    ///   fall back to except the one this rebuilds.
    ///
    /// The success path puts the answer back on the same anchor, exactly as the basename search
    /// does, and skips it if the chip has gone away in the meantime.
    private func grantAction(fallbackTo fallback: LinkResolution, relativeTo view: NSView) -> (() -> Void)? {
        guard let link = currentLink else { return nil }
        return { [weak self, weak view] in
            guard let self, let view else { return }
            self.searchTask?.cancel()
            let search = self.searchModel.beginSearch()
            // Put up *before* the task starts, so it is what the user finds when the modal panel
            // closes rather than a blank screen for however long a basename walk takes. Truthful in
            // the fast case too — it is opening either way.
            self.showSearching("Opening the archive\u{2026}", relativeTo: view)
            self.searchTask = Task { [weak self] in
                guard let self else { return }
                let outcome = await self.chooser.chooseRootAndResolve(
                    rootGUID: link.guid,
                    relativePath: link.relativePath,
                    progress: { [weak self] scanned in
                        self?.searchModel.advance(to: scanned, generation: search)
                    }
                )
                guard !Task.isCancelled else { return }
                guard let target = self.anchorView, target === view, target.window != nil else {
                    self.closePopover()
                    return
                }
                // A cancelled panel is not silence: the user is still looking at "Opening the
                // archive…" and needs it replaced with what they were looking at before they
                // pressed the button, not left spinning.
                self.present(outcome ?? fallback, page: link.page, relativeTo: target)
            }
        }
    }

    private func showSearching(_ headline: String, relativeTo anchor: NSView) {
        closePopover()
        let content = PreviewSearchingView(headline: headline, model: searchModel)
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

    private func showMessage(
        _ text: String,
        relativeTo anchorView: NSView,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        let button: PreviewMessageView.Action? = {
            guard let actionTitle, let action else { return nil }
            return PreviewMessageView.Action(title: actionTitle, perform: action)
        }()
        let content = PreviewMessageView(message: text, action: button)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: 300, height: button == nil ? 100 : 140)
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
    let headline: String
    @ObservedObject var model: PreviewSearchModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.small)
            Text(headline)
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
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let message: String
    var action: Action?

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical)
    }
}

// MARK: - Environment bridge

/// ObservableObject holding the `ReaderPreviewPopover`, passed as `@EnvironmentObject`
/// so `NoteEditorPane` can wire the preview callback without directly depending on the resolver.
@MainActor
final class SourceBlockPreviewState: ObservableObject {
    private let rootStore: ReaderRootStore
    private let preview: ReaderPreviewPopover
    /// Also driven from the File menu (`ArchiveNotesCommands.swift`), with no anchor and no link in
    /// hand — the other of the two entry points `ReaderRootChooser` exists for (W26.notesabsence-fu2).
    private let chooser: ReaderRootChooser

    init() {
        let store = ReaderRootStore()
        self.rootStore = store
        let resolver = ReaderLinkResolver(rootStore: store)
        let chooser = ReaderRootChooser(rootStore: store, resolver: resolver)
        self.chooser = chooser
        self.preview = ReaderPreviewPopover(resolver: resolver, chooser: chooser)
    }

    func show(for anchor: SourceAnchor, relativeTo view: NSView) {
        preview.show(for: anchor, relativeTo: view)
    }

    func dismiss() {
        preview.dismiss()
    }

    /// File ▸ Choose Archive Folder… — grant a Reader root with no link in hand.
    func chooseArchiveFolder() {
        chooser.chooseRoot()
    }
}
