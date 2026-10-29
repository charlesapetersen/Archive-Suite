import AppKit
import ArchiveCore

/// Persists (as a security-scoped bookmark) the Notes store root folder the user
/// granted, so the app can access it across launches within the sandbox.
///
/// Copied from Reader's `RootFolderStore` with the following changes:
/// - Defaults key is `"notesStoreRootBookmark"`.
/// - Provides a first-run app-default folder (`Application Support/ArchiveNotes/Store`).
/// - Calls `RootMarkerStore.ensureMarker` after resolving a root.
///
/// A picked store (File ▸ Choose Store Folder…, `StoreFolderChooser`) takes effect at the next launch:
/// `rememberRootAtQuit` writes the bookmark as the app terminates, and the app quits so the index, the
/// folder graph and every open editor are rebuilt against the new store rather than swapped underneath
/// (W40.fix-notes-choose-store).
@MainActor
final class RootFolderStore: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var marker: RootMarker?
    /// A store was chosen, but its bookmark no longer opens (a moved, deleted or unmounted folder).
    /// The default store is then NOT opened in its place: notes written there would land in a store
    /// the user did not pick, so the app shows no store and asks for the folder again.
    private(set) var savedRootUnavailable = false

    private let key = "notesStoreRootBookmark"
    private var defaults: UserDefaults
    private let defaultRoot: URL?
    private let notificationCenter: NotificationCenter
    private let readerRoots: [URL]
    /// A pick waiting for the quit that makes it take effect.
    private var pendingBookmark: Data?
    private var terminateObserver: NSObjectProtocol?
    /// The pending pick was written, because the app is terminating.
    private(set) var committedPendingRoot = false

    /// `Application Support/ArchiveNotes/Store` — the store a first launch opens.
    nonisolated static var standardDefaultRoot: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ArchiveNotes", isDirectory: true)
            .appendingPathComponent("Store", isDirectory: true)
    }

    /// - Parameters:
    ///   - defaults: where the chosen store's bookmark persists. Injected so a test never reads or
    ///     writes the app's real `notesStoreRootBookmark`.
    ///   - defaultRoot: the store opened when none was ever chosen. Injected for the same reason.
    ///   - notificationCenter: where `willTerminateNotification` arrives. Injected so a test can stand in
    ///     for the quit.
    ///   - readerRoots: the Reader archive folders Notes has been granted. A chosen store that is one of
    ///     them, or inside one, is not opened.
    init(defaults: UserDefaults = .standard, defaultRoot: URL? = RootFolderStore.standardDefaultRoot,
         notificationCenter: NotificationCenter = .default, readerRoots: [URL] = []) {
        self.readerRoots = readerRoots
        self.defaults = defaults
        self.defaultRoot = defaultRoot
        self.notificationCenter = notificationCenter
#if DEBUG
        // XCUITest sets -ANUITestStorePath <path> via launchArguments. The argument domain is
        // volatile (never written to disk), so this can never shadow a normal launch. We set
        // `root` directly without persisting a bookmark and without reading/writing
        // `notesStoreRootBookmark` — the real store root is never touched, and no default store
        // is bootstrapped (the override returns before resolveSaved()/bootstrapDefaultRoot()).
        if let path = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !path.isEmpty {
            // `-ANUITestStoreBookmarkSuite <suite>` lets a UITest drive Choose Store Folder… and the
            // relaunch after it: the pick persists into that throwaway suite, never the real key, and
            // the fixture stands in for the default store until something has been picked.
            if let suite = UserDefaults.standard.string(forKey: "ANUITestStoreBookmarkSuite"), !suite.isEmpty,
               let scratch = UserDefaults(suiteName: suite) {
                self.defaults = scratch
                resolveSaved()
                if root != nil || savedRootUnavailable { return }
            }
            adoptTestStore(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
#endif
        resolveSaved()
        if root == nil, !savedRootUnavailable, let defaultRoot {
            bootstrapDefaultRoot(defaultRoot)
        }
    }

    /// Remember a user-picked store folder for the next launch, written only when the app actually
    /// terminates: a quit that is called off must not leave the pick to switch stores at some later quit.
    /// Does not change `root`: the running app keeps its store until it quits (see the type comment).
    /// The bookmark is minted now, while the panel's grant is certainly live.
    func rememberRootAtQuit(_ url: URL) throws {
        pendingBookmark = try url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
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
        if let terminateObserver { notificationCenter.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    private func commitPendingRoot() {
        guard let pendingBookmark else { return }
        defaults.set(pendingBookmark, forKey: key)
        defaults.synchronize()   // the process is about to exit
        committedPendingRoot = true
        self.pendingBookmark = nil
    }

    // MARK: - Private

    private func resolveSaved() {
        guard let data = defaults.data(forKey: key) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            // Must start scope; if that fails, leave root nil (user re-picks). The default store is the
            // exception: it is inside the app's own container, reachable with no scope at all.
            let isDefault = defaultRoot.map { Self.samePath($0, url) } ?? false
            guard url.startAccessingSecurityScopedResource() || isDefault else {
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

    private func bootstrapDefaultRoot(_ defaultDir: URL) {
        do {
            try FileManager.default.createDirectory(at: defaultDir,
                                                    withIntermediateDirectories: true)
            root = defaultDir
            ensureMarkerQuietly()
        } catch {
            NSLog("RootFolderStore(Notes): could not create default store: \(error)")
        }
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
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
