import Foundation

/// One archive folder File ▸ Open Recent offers (W49.reader-ux-gaps-small): where it was, and the
/// security-scoped bookmark that reopens it, since the sandbox grants a folder only through a pick or a bookmark.
struct RecentArchiveFolder: Codable, Equatable, Identifiable, Sendable {
    var path: String
    var bookmark: Data
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

/// The archive folders opened most recently, newest first, kept in `key` as one JSON value so the File menu can
/// watch it through `@AppStorage`. Opening one goes through `RootFolderStore.setRoot(bookmark:)`, which writes
/// `archiveRootBookmark` as a pick does; nothing here touches that key.
enum RecentArchiveFolders {
    static let key = "ar.recentArchiveFolders"
    /// As many as Finder's Recent Folders keeps by default.
    static let limit = 10

    static func decode(_ data: Data?) -> [RecentArchiveFolder] {
        guard let data, let list = try? JSONDecoder().decode([RecentArchiveFolder].self, from: data) else { return [] }
        return list
    }

    static func list(in defaults: UserDefaults) -> [RecentArchiveFolder] { decode(defaults.data(forKey: key)) }

    /// `entry` first, any older entry for its path dropped, and no more than `limit`.
    static func noting(_ entry: RecentArchiveFolder, in list: [RecentArchiveFolder]) -> [RecentArchiveFolder] {
        Array(([entry] + list.filter { $0.path != entry.path }).prefix(limit))
    }

    /// Records the folder just opened. A folder macOS will not bookmark is left out rather than listed unopenable.
    static func note(_ url: URL, in defaults: UserDefaults) {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return }
        save(noting(RecentArchiveFolder(path: url.path, bookmark: bookmark), in: list(in: defaults)), in: defaults)
    }

    static func remove(path: String, in defaults: UserDefaults) {
        save(list(in: defaults).filter { $0.path != path }, in: defaults)
    }

    static func clear(in defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    private static func save(_ list: [RecentArchiveFolder], in defaults: UserDefaults) {
        if list.isEmpty { defaults.removeObject(forKey: key); return }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }
}
