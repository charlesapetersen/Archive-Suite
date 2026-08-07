// ReaderRootStore.swift — GUID-keyed security-scoped bookmarks to Reader roots
// Part of Archive Notes (W4-S5).
// W26.notesabsence-fu1: a root that IS a symbolic link can now be granted — it is adopted as its
// target, because a security-scoped bookmark cannot open a link — and every way a grant can fail
// returns a refusal the caller can SAY, instead of a marker that implies success.
// W26.notesabsence-fu3: READING a root can no longer WRITE the bookmark dictionary, so one root
// whose scope will not start can no longer take every other granted root down with it; and a scope
// that was never started is never stopped.

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
    /// It is an Archive root, but of the wrong kind — the likely pick being Archive Notes' own
    /// notes folder, which carries a `.notes` marker (`RootFolderStore` writes one).
    ///
    /// Newly reachable as of `W26.notesabsence-fu2`: until Notes had a folder chooser, the only
    /// folders ever handed to `grantRoot` came from tests. Adopting one would "succeed" and then
    /// satisfy no link ever, because a Reader link's GUID is a *Reader* root's GUID.
    case wrongRootKind(URL, RootKind)
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
        case let .wrongRootKind(url, kind):
            switch kind {
            case .notes:
                return "“\(url.lastPathComponent)” is your Archive Notes folder, not an archive of "
                    + "scanned documents. Choose the folder Archive Reader opens."
            case .reader:
                // Unreachable while `.reader` is what this store wants; kept exhaustive so adding a
                // third kind is a compile error here rather than a wrong sentence at runtime.
                return "“\(url.lastPathComponent)” is not the right kind of archive folder."
            }
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

    /// One root's live access, as this store understands it.
    ///
    /// `started` is the half that used to be missing. `startAccessingSecurityScopedResource()`
    /// returns **false** for a URL that is already accessible without a scope — the panel URL a
    /// fresh grant hands over, and every URL in a test running from the app container — and Apple
    /// is explicit that a `false` start must not be balanced by a stop. Recording the URL without
    /// recording *that* made `stopAccessing(guid:)` stop a scope it had never started.
    private struct Scope {
        let url: URL
        /// `true` only if *this store* started the scope and therefore owes it a stop.
        let started: Bool
    }

    /// Live access keyed by GUID, so we can stop what we started — and only that.
    private var activeScopes: [UUID: Scope] = [:]
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

    /// How a security scope is started, and how it is given back.
    ///
    /// Test seams for the same reason `mintBookmark` is one, and the reason is the whole of
    /// `W26.notesabsence-fu3`: the branch that matters — a bookmark that resolves at launch but
    /// whose scope will not start, because the volume is not mounted — cannot be provoked from a
    /// test. Every fixture lives in the app container, where a start is *always* refused for the
    /// opposite reason (the URL needs no scope), so without a seam the failure branch would run
    /// only in the wrong sense and a mutation putting the whole-dictionary rewrite back would pass.
    /// `stopScope` is separate so a test can prove a stop that must NOT happen did not happen.
    var startScope: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopScope: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }

    /// - Parameter defaults: where the bookmarks are persisted. Injected so a test can hand over a
    ///   throwaway suite: `grantRoot` WRITES, and `readerRootBookmarks` in `.standard` is the app's
    ///   real set of granted Reader roots.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadSaved()
    }

    /// Look up a Reader root by its marker GUID.
    /// Starts the security scope if not already active; returns `nil` on miss.
    ///
    /// **This is a read. It writes nothing to `UserDefaults` (`W26.notesabsence-fu3`).** It used to:
    /// a scope that would not start was treated as proof the bookmark was dead, the GUID was dropped
    /// and `persistAll()` rebuilt the *whole* `readerRootBookmarks` dictionary by re-minting every
    /// surviving root — with no scope started, which is exactly the condition under which minting
    /// fails. So one click into a root whose volume was not mounted silently deleted the persisted
    /// bookmark of every *other* root as collateral.
    ///
    /// Two separate corrections, and the second is the one that outlives this function:
    ///
    /// 1. **The failed root's own bookmark also stays.** A refused start is not proof of staleness —
    ///    an unmounted volume refuses one and remounts later — and Notes has no folder chooser at all
    ///    (`W26.notesabsence-fu2`), so forgetting a grant here is unrecoverable by the user. The
    ///    Reader reached the same conclusion on the same question and says so in
    ///    `RootFolderStore.reResolveSavedRoot`: *"The bookmark remains persisted so a later window
    ///    activation can retry after the volume is mounted again."* This deviates from the filed
    ///    item, which asked only that the *other* roots be spared.
    /// 2. **`persistAll` is gone entirely**, so no code path re-mints during a read. Narrowing it to
    ///    delete one key would have left the shape of the bug — a lookup that rewrites the store —
    ///    in place for the next edit to widen again.
    ///
    /// The GUID is still dropped from `knownRoots`, in memory: this session cannot open that root, so
    /// handing its URL back would only produce failures further downstream. The next launch retries.
    func root(for guid: UUID) -> URL? {
        if let scope = activeScopes[guid] {
            return scope.url
        }
        guard let url = knownRoots[guid] else { return nil }
        guard startScope(url) else {
            knownRoots.removeValue(forKey: guid)
            return nil
        }
        activeScopes[guid] = Scope(url: url, started: true)
        return url
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
        // A `.notes` marker is a real Archive root — Notes writes one at its own store — so it gets
        // past `notAnArchiveRoot` and would be adopted, keyed by a GUID no Reader link can ever
        // name. Refusing it is only worth saying now that a user can pick a folder at all
        // (`W26.notesabsence-fu2`); the notes folder is the plausible mis-pick, being the one
        // folder Notes already talks about.
        guard marker.kind == .reader else {
            return .refused(.wrongRootKind(url, marker.kind))
        }

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
            let started: Bool
            if let previous, previous.url == target, previous.started {
                // Already inside a scope for this exact URL. start/stop are balanced per call and
                // nothing here counts them, so a second start would leave one that can never be
                // given back — the old code's re-grant-at-the-same-path case.
                started = true
            } else {
                // `false` here is normal, not a failure: a panel URL is already accessible, so there
                // is no scope to start and — Apple is explicit — none to stop later either.
                started = startScope(target)
            }
            activeScopes[marker.guid] = Scope(url: target, started: started)
            knownRoots[marker.guid] = target
            if let previous, previous.url != target, previous.started {
                stopScope(previous.url)
            }
            return .granted(marker)
        } catch {
            NSLog("ReaderRootStore: could not bookmark \(target.path): \(error)")
            return .refused(.couldNotBookmark(url, "\(error)"))
        }
    }

    /// Stop the security scope for the given root. Does not remove the bookmark.
    ///
    /// Stops **only a scope this store started** (`W26.notesabsence-fu3`). Apple's rule is that a
    /// `startAccessingSecurityScopedResource()` returning `false` must not be paired with a stop, and
    /// this used to pair it with one for every root granted in the current session — a grant's URL
    /// comes from the open panel, which is accessible without a scope, so its start always returns
    /// `false`.
    ///
    /// A never-started entry is also **kept**, not dropped: the panel's grant lasts as long as the
    /// process, so the URL is still the right answer for `root(for:)`. Dropping it sent the next
    /// lookup down the `knownRoots` path, where the start refused again — and, before the fix above,
    /// that refusal wiped every persisted bookmark in the store. Losing a whole session's roots by
    /// closing a popover was two lines apart.
    func stopAccessing(guid: UUID) {
        guard let scope = activeScopes[guid], scope.started else { return }
        activeScopes.removeValue(forKey: guid)
        stopScope(scope.url)
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

    /// Re-mint one stale bookmark, touching **only that GUID's entry**.
    ///
    /// This was already the right shape when `persistAll()` was the wrong one, and the difference is
    /// instructive: minting needs a live scope, which is why this starts one first. `persistAll()`
    /// re-minted without ever starting a scope, so its `try?` swallowed a failure that was more or
    /// less guaranteed — and wrote the resulting gap back over the store.
    private func refreshBookmark(guid: UUID, url: URL) {
        guard startScope(url) else { return }
        defer { stopScope(url) }
        if let fresh = try? mintBookmark(url) {
            var stored = savedBookmarks()
            stored[guid.uuidString.lowercased()] = fresh
            defaults.set(stored, forKey: defaultsKey)
        }
    }
}
