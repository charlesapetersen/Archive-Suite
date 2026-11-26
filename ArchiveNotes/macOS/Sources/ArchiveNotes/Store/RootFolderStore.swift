import AppKit
import ArchiveCore

/// Persists (as a security-scoped bookmark) the Notes library the user made or opened, so the app can
/// access it across launches within the sandbox.
///
/// Copied from Reader's `RootFolderStore` with the following changes:
/// - Defaults key is `"notesStoreRootBookmark"`.
/// - Calls `RootMarkerStore.ensureMarker` after resolving a root.
///
/// The store is an `.archivenotes` library package the user can see, name and move (owner, 2026-11-20,
/// call 24; W49.notes-store-format). There is no default store: until one is made or opened `root` is nil
/// and `needsLibrary` is true, and the first launch asks where to make one (`StoreFolderChooser.newLibrary`).
///
/// A picked library (File ▸ New Library… or Open Library…, `StoreFolderChooser`) takes effect at the next launch:
/// `rememberRootAtQuit` writes the bookmark as the app terminates, and the app quits so the index, the
/// folder graph and every open editor are rebuilt against the new store rather than swapped underneath
/// (W40.fix-notes-choose-store).
@MainActor
final class RootFolderStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var marker: RootMarker?
    /// A store was chosen, but its bookmark no longer opens (a moved, deleted or unmounted folder).
    /// The app then shows no store and asks for the library again.
    private(set) var savedRootUnavailable = false
    /// No library was ever made or opened: the first launch, which asks for one.
    var needsLibrary: Bool { root == nil && !savedRootUnavailable }
    /// File ▸ Open Recent: every library a launch has opened, kept in the same defaults as the bookmark.
    let recentLibraries: RecentLibraries

    private let key = "notesStoreRootBookmark"
    private var defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let readerRoots: [URL]
    /// A pick waiting for the quit that makes it take effect.
    private var pendingBookmark: Data?
    /// Run once the pending pick is written, as the app terminates: Restart and Switch's relaunch.
    private var afterCommit: (@MainActor () -> Void)?
    private var terminateObserver: NSObjectProtocol?
    /// The pending pick was written, because the app is terminating.
    private(set) var committedPendingRoot = false

    /// The store folder a launch opens, resolved and nothing more: no scope started, nothing written.
    /// For `ReaderRootStore.grantRoot`, which must not give an archive identity to a folder that holds
    /// the notes store, or one inside it (W40.root-marker-auto).
    nonisolated static func savedStoreFolder(defaults: UserDefaults = .standard) -> URL? {
#if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
#endif
        if let data = defaults.data(forKey: "notesStoreRootBookmark") {
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        return nil
    }

    /// - Parameters:
    ///   - defaults: where the chosen store's bookmark persists. Injected so a test never reads or
    ///     writes the app's real `notesStoreRootBookmark`.
    ///   - notificationCenter: where `willTerminateNotification` arrives. Injected so a test can stand in
    ///     for the quit.
    ///   - readerRoots: the Reader archive folders Notes has been granted. A chosen store that is one of
    ///     them, or inside one, is not opened.
    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default, readerRoots: [URL] = []) {
        self.readerRoots = readerRoots
        self.defaults = defaults
        self.notificationCenter = notificationCenter
#if DEBUG
        // XCUITest sets -ANUITestStorePath <path> via launchArguments. The argument domain is
        // volatile (never written to disk), so this can never shadow a normal launch. We set
        // `root` directly without persisting a bookmark and without reading/writing
        // `notesStoreRootBookmark` — the real store root is never touched (the override returns
        // before resolveSaved()).
        if let path = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !path.isEmpty {
            // `-ANUITestStoreBookmarkSuite <suite>` lets a UITest drive Open Library… and the
            // relaunch after it: the pick persists into that throwaway suite, never the real key, and
            // the fixture stands in for the store until something has been picked.
            if let suite = UserDefaults.standard.string(forKey: "ANUITestStoreBookmarkSuite"), !suite.isEmpty,
               let scratch = UserDefaults(suiteName: suite) {
                self.defaults = scratch
                recentLibraries = RecentLibraries(defaults: scratch)
                // `-ANUITestNoLibrary YES` starts with no library open, as a first launch does, so a UITest can
                // see the No Library Open state (W49.notes-library-ux); the first-launch Save panel is not
                // shown. Only with a bookmark suite, so a pick made from that state never reaches the real key.
                if Self.uiTestNoLibrary { return }
                resolveSaved()
                if root != nil || savedRootUnavailable { return }
            } else {
                // The fixture is never put on the app's own Open Recent list.
                recentLibraries = RecentLibraries(defaults: nil)
            }
            adoptTestStore(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
#endif
        recentLibraries = RecentLibraries(defaults: defaults)
        resolveSaved()
    }

    /// Remember a user-picked store folder for the next launch, written only when the app actually
    /// terminates: a quit that is called off must not leave the pick to switch stores at some later quit.
    /// Does not change `root`: the running app keeps its store until it quits (see the type comment).
    /// The bookmark is minted now, while the panel's grant is certainly live. `then` runs after the pick is
    /// written, so a relaunch it starts reads the new store, and never for a quit that is called off.
    func rememberRootAtQuit(_ url: URL, then afterCommit: (@MainActor () -> Void)? = nil) throws {
        pendingBookmark = try url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        self.afterCommit = afterCommit
        committedPendingRoot = false
        guard terminateObserver == nil else { return }
        terminateObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitPendingRoot() }
        }
    }

    /// Forget a pick whose quit was called off.
    func discardPendingRoot() {
        pendingBookmark = nil
        afterCommit = nil
        if let terminateObserver { notificationCenter.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    private func commitPendingRoot() {
        guard let pendingBookmark else { return }
        defaults.set(pendingBookmark, forKey: key)
        defaults.synchronize()   // the process is about to exit
        committedPendingRoot = true
        self.pendingBookmark = nil
        let afterCommit = self.afterCommit
        self.afterCommit = nil
        afterCommit?()
    }

    // MARK: - Private

    private func resolveSaved() {
        guard let data = defaults.data(forKey: key) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // Must start scope; if that fails, leave root nil (user re-picks).
            guard url.startAccessingSecurityScopedResource() else {
                NSLog("RootFolderStore(Notes): saved root is no longer accessible; user must re-pick.")
                savedRootUnavailable = true
                return
            }
            // Check it again, as the pick was checked: since then it may have become a Reader archive,
            // or files may have landed in the empty folder that was picked. A refused folder is not
            // opened, so no marker is written into it and no note is saved there.
            if case let .refused(refusal) = StoreFolderChooser.check(url, readerRoots: readerRoots) {
                NSLog("RootFolderStore(Notes): saved root \(url.path) is no longer a store (\(refusal)).")
                savedRootUnavailable = true
                return
            }
            // The scope is held for the life of the process: the store is in use until it quits.
            root = url
            recentLibraries.note(url)
            // Refresh a stale bookmark while access is still held.
            if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                        includingResourceValuesForKeys: nil,
                                                        relativeTo: nil) {
                defaults.set(fresh, forKey: key)
            }
            ensureMarkerQuietly()
        } catch {
            NSLog("RootFolderStore(Notes): could not resolve saved bookmark: \(error)")
            savedRootUnavailable = true
        }
    }

    private func ensureMarkerQuietly() {
        guard let root else { return }
        do {
            marker = try RootMarkerStore.ensureMarker(at: root, kind: .notes)
        } catch {
            NSLog("RootFolderStore(Notes): marker error: \(error)")
            marker = nil
        }
    }

#if DEBUG
    /// `-ANUITestNoLibrary` under the UITest harness with a bookmark suite (see `init`).
    static var uiTestNoLibrary: Bool {
        guard let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty,
              let s = UserDefaults.standard.string(forKey: "ANUITestStoreBookmarkSuite"), !s.isEmpty
        else { return false }
        return UserDefaults.standard.bool(forKey: "ANUITestNoLibrary")
    }

    /// Set the store root for UI testing without persisting a bookmark or starting a security
    /// scope. The fixture path is accessible via the UITest-only temporary-exception entitlement,
    /// so no security-scoped resource dance is needed. This method does NOT read or write
    /// `notesStoreRootBookmark` in UserDefaults — the real store root is never touched — and it
    /// never CREATES a marker (it only reads one the fixture builder may provide).
    private func adoptTestStore(_ url: URL) {
        root = url
        // No scope to release. No bookmark persisted.
        // Read (but don't create) a marker if present — the fixture builder may provide one.
        marker = try? RootMarker.read(at: url)
    }
#endif
}
