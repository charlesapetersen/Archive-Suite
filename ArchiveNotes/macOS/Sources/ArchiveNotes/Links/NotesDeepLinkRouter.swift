// NotesDeepLinkRouter.swift — parse + dispatch archivenotes:// URLs
// Part of Archive Notes (W4-S5).

import Foundation
import ArchiveCore

/// Parses incoming `archivenotes://open?id=<UUID>[#block-<n>]` URLs and holds
/// the latest request until the app's navigation model has loaded its index.
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

    /// Forwards a pending request once the initial item index is settled, then clears it.
    ///
    /// The readiness gate matters at launch: resolving an otherwise-valid link against the empty
    /// pre-bootstrap list would incorrectly present it as a deleted note. The app supplies the
    /// navigation-model handoff so this parser stays independent of navigation and windows.
    @discardableResult
    func forwardPendingOpen(whenIndexReady: Bool, _ forward: (PendingOpen) -> Void) -> Bool {
        guard whenIndexReady, let pendingOpen else { return false }
        forward(pendingOpen)
        clearPending()
        return true
    }

    /// Discards the pending request without navigating. Used only when the receiving layer explicitly
    /// abandons an already-forwarded request.
    func clearPending() {
        pendingOpen = nil
    }
}
