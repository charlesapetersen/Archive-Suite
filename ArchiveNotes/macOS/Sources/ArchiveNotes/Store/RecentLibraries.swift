import Foundation

/// File ▸ Open Recent (W49.notes-library-ux): the libraries this Mac has opened, newest first.
///
/// A library joins the list when a launch opens it (`RootFolderStore.resolveSaved`), so the list holds only
/// libraries that passed the launch's checks. Each entry keeps a security-scoped bookmark, minted while the
/// launch holds the library's scope, so a later Open Recent can reach it again under the sandbox; the path is
/// kept beside it for the menu, which then needs no bookmark resolved to draw. Choosing an entry goes through
/// Open Library…'s checks and confirmation (`StoreFolderChooser.use`); nothing here switches or writes a
/// library.
///
/// `defaults` nil keeps the list in memory only: a UITest launch on the fixture neither reads nor writes the
/// app's own list.
@MainActor
final class RecentLibraries: ObservableObject {

    struct Entry: Equatable, Identifiable, Sendable {
        /// The library's canonical path when it was last opened.
        let path: String
        let bookmark: Data
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
        /// The library's name as Finder shows it, without `.archivenotes`.
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    nonisolated static let key = "notesRecentLibraries"
    nonisolated static let limit = 10

    @Published private(set) var entries: [Entry] = []
    private let defaults: UserDefaults?

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        entries = Self.load(from: defaults)
    }

    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Put `url` at the top of the list (moving it if already there), with a fresh bookmark. Call it while
    /// the library's scope is held. A library macOS will not bookmark is left out, never stored half-made.
    func note(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        let path = Self.canonicalPath(url)
        var next = entries.filter { $0.path != path }
        next.insert(Entry(path: path, bookmark: bookmark), at: 0)
        entries = Array(next.prefix(Self.limit))
        save()
    }

    /// Drop one entry, e.g. a library that can no longer be found.
    func remove(_ entry: Entry) {
        entries.removeAll { $0.path == entry.path }
        save()
    }

    /// File ▸ Open Recent ▸ Clear Menu.
    func clear() {
        entries = []
        save()
    }

    /// The entry's library, with its security scope started, or nil when its bookmark no longer opens (moved
    /// to another disk, deleted, unmounted). The caller stops the scope once it is done with the library.
    func resolve(_ entry: Entry) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: entry.bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        return url
    }

    /// The menu title: the library's name, and where it is when two libraries share a name.
    func title(for entry: Entry) -> String {
        guard entries.contains(where: { $0.path != entry.path && $0.name == entry.name }) else { return entry.name }
        let folder = entry.url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let place = folder.path.hasPrefix(home + "/") ? "~" + folder.path.dropFirst(home.count) : folder.path
        return "\(entry.name) — \(place)"
    }

    // MARK: - Storage

    private func save() {
        defaults?.set(entries.map { ["path": $0.path, "bookmark": $0.bookmark] as [String: Any] }, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults?) -> [Entry] {
        guard let raw = defaults?.array(forKey: key) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return raw.compactMap { dict -> Entry? in
            guard let path = dict["path"] as? String, let bookmark = dict["bookmark"] as? Data,
                  seen.insert(path).inserted else { return nil }
            return Entry(path: path, bookmark: bookmark)
        }
        .prefix(limit).map { $0 }
    }
}
