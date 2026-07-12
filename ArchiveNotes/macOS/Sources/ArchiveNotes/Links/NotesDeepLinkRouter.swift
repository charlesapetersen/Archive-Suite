// NotesDeepLinkRouter.swift — parse + dispatch archivenotes:// URLs
// Part of Archive Notes (W4-S5).

import Foundation
import ArchiveCore

/// Parses incoming `archivenotes://open?id=<UUID>[#block-<n>]` URLs and
/// dispatches them to the Notes navigation model.
///
/// W6 will add a `NotesModel.openItem(id:block:)` method that the router
/// calls; until then, we stash the pending open request so W6 can pick it up.
@MainActor
final class NotesDeepLinkRouter: ObservableObject {
    /// The most recent deep-link open request, consumed by the navigation layer.
    @Published private(set) var pendingOpen: PendingOpen?

    struct PendingOpen: Equatable, Sendable {
        let id: UUID
        let block: Int?
    }

    func handle(_ url: URL) {
        guard case .notesOpen(let id, let block) = DurableLink(url: url) else {
            return
        }
        pendingOpen = PendingOpen(id: id, block: block)
    }

    /// Called by the navigation layer after it has consumed the pending request.
    func clearPending() {
        pendingOpen = nil
    }
}
