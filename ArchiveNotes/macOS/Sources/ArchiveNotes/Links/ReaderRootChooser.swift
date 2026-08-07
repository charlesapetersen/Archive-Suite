// ReaderRootChooser.swift — the only way a person can give Archive Notes an archive folder
// W26.notesabsence-fu2.
//
// Everything under `Links/` could already grant a Reader root, resolve a link inside it and say
// precisely why a grant was refused. Nothing could ASK. `ReaderRootStore.grantRoot`'s only caller
// was `ReaderLinkResolver.grantAndResolve`, whose only callers were tests, and `NSOpenPanel`
// appeared nowhere in Notes' sources — so `knownRoots` started empty and stayed empty on every
// machine, every source-block preview ended at `.needsRootGrant`, and the popover's advice ("choose
// the folder in Reader") could not work: Notes is sandboxed, and a folder granted to *Reader*
// conveys no access to *Notes*.
//
// This is the missing half: a panel, and the two ways it is used — from the File menu, where there
// is no link in hand, and from the preview popover, which knows exactly which root it wants.

import AppKit
import Foundation
import ArchiveCore

/// Asks the user for an Archive Reader folder and grants it to Notes.
///
/// The panel is behind a seam (`pickFolder`) and so is the way an outcome is shown (`report`),
/// which is what makes both entry points testable without a window: an `NSOpenPanel` or an
/// `NSAlert` opened from a unit-test host blocks the whole bundle until someone dismisses it, and
/// nobody is there to.
@MainActor
final class ReaderRootChooser {

    /// What came of asking. `cancelled` is a first-class answer, not a failure — the user said no,
    /// and nothing should be said back to them about it.
    enum Outcome: Equatable, Sendable {
        case cancelled
        /// Granted. Carries the folder **as picked** alongside the marker, because for a symlinked
        /// pick the adopted target's last component is a name the user never saw
        /// (`ReaderRootGrantRefusal` names the pick for the same reason).
        case granted(RootMarker, picked: URL)
        case refused(ReaderRootGrantRefusal)

        /// Title + body for the alert this outcome deserves, or `nil` if it deserves none.
        ///
        /// A grant is worth confirming even though it succeeded: unlike Reader, where choosing a
        /// folder visibly fills a window, granting an archive to Notes changes nothing on screen
        /// until the next time a source chip is clicked. Silence after a modal pick reads as
        /// failure.
        var alert: (title: String, body: String)? {
            switch self {
            case .cancelled:
                return nil
            case let .granted(marker, picked):
                return ("Archive folder ready",
                        "“\(picked.lastPathComponent)” is now open in Archive Notes. "
                            + "Source links into \(marker.name) will open here.")
            case let .refused(refusal):
                return ("Could not open that folder", refusal.message)
            }
        }
    }

    private let rootStore: ReaderRootStore
    private let resolver: ReaderLinkResolver

    /// How the folder is asked for. A test seam, not a policy knob — see the type doc.
    var pickFolder: @MainActor () -> URL? = { ReaderRootChooser.runOpenPanel() }

    /// How an outcome is shown. Seam for the same reason.
    var report: @MainActor (Outcome) -> Void = { ReaderRootChooser.presentAlert(for: $0) }

    init(rootStore: ReaderRootStore, resolver: ReaderLinkResolver) {
        self.rootStore = rootStore
        self.resolver = resolver
    }

    // MARK: - The two entry points

    /// File ▸ Choose Archive Folder… — grant a root with no link in hand.
    ///
    /// There is no resolution to do and nothing on screen to update, so the outcome is *said*
    /// rather than drawn.
    @discardableResult
    func chooseRoot() -> Outcome {
        guard let url = pickFolder() else { return .cancelled }
        let outcome: Outcome
        switch rootStore.grantRoot(url) {
        case let .granted(marker):
            outcome = .granted(marker, picked: url)
        case let .refused(refusal):
            outcome = .refused(refusal)
        }
        report(outcome)
        return outcome
    }

    /// The in-context variant: the preview popover already knows which root the link names, so the
    /// pick can be granted *and* the link re-resolved in one step.
    ///
    /// - Returns: the resolution to show, or `nil` if the user cancelled the panel — in which case
    ///   the popover has nothing new to say and should not replace what it was showing.
    func chooseRootAndResolve(
        rootGUID: UUID,
        relativePath: String,
        progress: (@MainActor @Sendable (Int) -> Void)? = nil
    ) async -> LinkResolution? {
        guard let url = pickFolder() else { return nil }
        return await resolver.grantAndResolve(
            url: url, rootGUID: rootGUID, relativePath: relativePath, progress: progress
        )
    }

    // MARK: - The real panel and the real alert

    /// The same panel Reader's `NavigationModel.chooseRoot` runs, worded for Notes.
    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Archive Folder"
        panel.message = "Choose the archive folder Archive Reader opens, "
            + "so source links can be previewed here."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func presentAlert(for outcome: Outcome) {
        guard let (title, body) = outcome.alert else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = {
            if case .granted = outcome { return .informational }
            return .warning
        }()
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
