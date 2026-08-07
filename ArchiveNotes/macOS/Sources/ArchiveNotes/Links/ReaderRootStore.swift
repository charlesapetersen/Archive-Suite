// ReaderRootStore.swift — GUID-keyed security-scoped bookmarks to Reader roots
// Part of Archive Notes (W4-S5).
// W26.notesabsence-fu1: a root that IS a symbolic link can now be granted — it is adopted as its
// target, because a security-scoped bookmark cannot open a link — and every way a grant can fail
// returns a refusal the caller can SAY, instead of a marker that implies success.

import Foundation
import ArchiveCore

/// Why a chosen folder could not be granted as a Reader root.
///
/// Returned so the caller can *say so*. Until `W26.notesabsence-fu1` none of these reached the
/// caller: two were a bare `nil` (indistinguishable from each other), and the third — the bookmark
/// failure, which is what a symlinked root hit every time — returned the `RootMarker` that had
/// already been read, so the caller believed the grant had worked while `knownRoots` stayed empty.
///
/// Every case carries the folder **as picked**, never the canonicalised target — see `grantRoot`.
enum ReaderRootGrantRefusal: Equatable, Sendable {
    /// The folder cannot be opened at all: missing, permission-denied, a dangling symlink, an
    /// `ELOOP` cycle, or not a directory.
    case unreadable(URL)
    /// It opens, but carries no `.archive-suite-root.json` — it is not an Archive root at all.
    case notAnArchiveRoot(URL)
    /// A marker file is there and could not be read or decoded. Distinct from `notAnArchiveRoot` on
    /// purpose (W23.m6): the repair for absence is to mint a fresh GUID, which would orphan every
    /// link already written from this root, so "unreadable identity" must never read as "no identity".
    case markerUnreadable(URL, String)
    /// It opens and it is an Archive root, but macOS refused to mint a security-scoped bookmark for
    /// it, so access could not survive the next launch — adopting it anyway would work until then.
    case couldNotBookmark(URL, String)

    var message: String {
        switch self {
        case let .unreadable(url):
            return "Could not open “\(url.lastPathComponent)”. "
                + "Check that the folder still exists and that you have permission to read it."
        case let .notAnArchiveRoot(url):
            return "“\(url.lastPathComponent)” is not an Archive Reader folder. "
                + "Choose the archive folder Reader itself opens."
        case let .markerUnreadable(url, _):
            return "Could not read the archive identity in “\(url.lastPathComponent)”, "
                + "so it was not opened."
        case let .couldNotBookmark(url, _):
            return "Could not keep access to “\(url.lastPathComponent)”, so it was not opened."
        }
    }
}

/// The outcome of `ReaderRootStore.grantRoot`.
///
/// A two-case enum rather than an optional marker because the failure that motivated
/// `W26.notesabsence-fu1` was precisely a *non-nil* return on a grant that had not happened.
enum ReaderRootGrant: Equatable, Sendable {
    case granted(RootMarker)
    case refused(ReaderRootGrantRefusal)

    /// The marker if the grant succeeded, `nil` if it was refused — for the call sites that only
    /// need to know whether the root is usable now.
    var marker: RootMarker? {
        if case let .granted(marker) = self { return marker }
        return nil
    }

    /// Why the grant was refused, `nil` if it succeeded.
    var refusal: ReaderRootGrantRefusal? {
        if case let .refused(refusal) = self { return refusal }
        return nil
    }
}

/// Manages security-scoped bookmarks to Archive Reader root folders,
/// keyed by their `RootMarker.guid`.
///
/// When Notes resolves a `DurableLink.readerReveal`, it looks up the root
/// GUID here. On first encounter (new machine or unknown GUID) the user
/// grants access via an open panel; the bookmark is stored for future use.
@MainActor
final class ReaderRootStore: ObservableObject {
    @Published private(set) var knownRoots: [UUID: URL] = [:]

    /// Active security scopes keyed by GUID, so we can stop them on removal.
    private var activeScopes: [UUID: URL] = [:]
    private let defaultsKey = "readerRootBookmarks"
    private let defaults: UserDefaults

    /// How `grantRoot` mints its security-scoped bookmark.
    ///
    /// A test seam, not a policy knob. The one branch this store exists to get right — `bookmarkData`
    /// failing for a folder that opens and carries a marker — cannot be provoked otherwise: every
    /// fixture lives in the app container, where minting always succeeds, so the `catch` that used to
    /// return a success-implying marker would sit unexercised and a mutation restoring the bug would
    /// pass. (A symlink is no longer a way in, because that is exactly what the fix stops.)
    var mintBookmark: (URL) throws -> Data = { url in
        try url.bookmarkData(options: .withSecurityScope,
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// - Parameter defaults: where the bookmarks are persisted. Injected so a test can hand over a
    ///   throwaway suite: `grantRoot` WRITES, and `readerRootBookmarks` in `.standard` is the app's
    ///   real set of granted Reader roots.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSaved()
    }

    /// Look up a Reader root by its marker GUID.
    /// Starts the security scope if not already active; returns `nil` on miss.
    func root(for guid: UUID) -> URL? {
        if let url = activeScopes[guid] {
            return url
        }
        guard let url = knownRoots[guid] else { return nil }
        if url.startAccessingSecurityScopedResource() {
            activeScopes[guid] = url
            return url
        }
        // Bookmark is stale / no longer accessible — remove it.
        knownRoots.removeValue(forKey: guid)
        persistAll()
        return nil
    }

    /// Register a newly-granted Reader root: read its `RootMarker` for the GUID, persist a
    /// security-scoped bookmark, and start the scope.
    ///
    /// The folder is adopted as `CorpusWalker.canonicalRoot(url)` rather than as picked, because
    /// `bookmarkData(options: .withSecurityScope)` **cannot open a symbolic link** — measured in the
    /// Notes test host 2026-08-07, it throws `NSCocoaErrorDomain 256` "Could not open() the item"
    /// for a link to a perfectly readable directory while succeeding for that same directory. It
    /// differs from the picked URL *only* for a symlinked final component (`canonicalRoot` returns
    /// every other root byte-unchanged), so no root that works today can shift — and the bookmark is
    /// minted for the same URL that is stored, so the scope belongs to the root we keep.
    ///
    /// Every refusal names the folder **as picked**, not the canonicalised target: that is the name the
    /// user chose, and for a symlinked pick the target's last component is a folder they never saw.
    ///
    /// - Returns: `.granted(marker)`, or `.refused(_)` carrying a reason the caller can show.
    @discardableResult
    func grantRoot(_ url: URL) -> ReaderRootGrant {
        guard let target = CorpusWalker.canonicalRoot(url) else { return .refused(.unreadable(url)) }

        let found: RootMarker?
        do {
            found = try RootMarker.read(at: target)
        } catch {
            return .refused(.markerUnreadable(url, "\(error)"))
        }
        guard let marker = found else { return .refused(.notAnArchiveRoot(url)) }

        do {
            let data = try mintBookmark(target)
            // Store the raw bookmark data keyed by lowercased GUID string.
            var stored = savedBookmarks()
            stored[marker.guid.uuidString.lowercased()] = data
            defaults.set(stored, forKey: defaultsKey)

            // Re-granting the same GUID at a different path must release the scope it replaces —
            // `activeScopes` holds one URL per GUID, so overwriting it would drop the only reference
            // that could ever balance the old `start`. (`RootFolderStore.setRoot` does the same, in
            // the same order: new access live before the old one is let go.)
            let previous = activeScopes[marker.guid]
            _ = target.startAccessingSecurityScopedResource() // false for a panel URL; it is already accessible
            activeScopes[marker.guid] = target
            knownRoots[marker.guid] = target
            if let previous, previous != target { previous.stopAccessingSecurityScopedResource() }
            return .granted(marker)
        } catch {
            NSLog("ReaderRootStore: could not bookmark \(target.path): \(error)")
            return .refused(.couldNotBookmark(url, "\(error)"))
        }
    }

    /// Stop the security scope for the given root. Does not remove the bookmark.
    func stopAccessing(guid: UUID) {
        if let url = activeScopes.removeValue(forKey: guid) {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Private

    private func savedBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: defaultsKey) as? [String: Data] ?? [:]
    }

    private func loadSaved() {
        for (guidStr, data) in savedBookmarks() {
            guard let guid = UUID(uuidString: guidStr) else { continue }
            var stale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                knownRoots[guid] = url
                // Don't start scope eagerly — do it on demand in root(for:).
                if stale {
                    refreshBookmark(guid: guid, url: url)
                }
            } catch {
                NSLog("ReaderRootStore: could not resolve bookmark for \(guidStr): \(error)")
            }
        }
    }

    private func refreshBookmark(guid: UUID, url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        if let fresh = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            var stored = savedBookmarks()
            stored[guid.uuidString.lowercased()] = fresh
            defaults.set(stored, forKey: defaultsKey)
        }
    }

    private func persistAll() {
        var stored: [String: Data] = [:]
        for (guid, url) in knownRoots {
            if let data = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                stored[guid.uuidString.lowercased()] = data
            }
        }
        defaults.set(stored, forKey: defaultsKey)
    }
}
