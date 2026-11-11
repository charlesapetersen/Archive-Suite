import Foundation
import ArchiveCore

/// What changed in `ArchiveLibrary.files` since the model last looked (W40.fix-reader-change-incremental).
///
/// One type for both sources of a change: a `CorpusWatcher` batch merged by `ArchiveLibrary.apply`, and
/// `TagWriter`'s verified writes through `applyVerifiedWrites`. Each changed row carries its value before and
/// after, so a consumer acts on those rows alone: the list patches them in place, the smart-folder counts move
/// by their difference, and nothing that only depends on paths or text runs for a tag change. `rows == nil`
/// means the whole library may have changed (a walk, a warm snapshot, a subtree read), and the consumer
/// rebuilds as it always did.
///
/// Changes accumulate between takes, so a consumer that coalesces several publishes still sees every row.
/// Display-only: nothing here reads or writes a file.
struct LibraryChangeSet: Sendable {
    struct Row: Sendable {
        /// The row before the first change since the last take; nil when the path was not listed.
        let old: ArchiveFile?
        /// The row now; nil when it has left the library.
        var new: ArchiveFile?
    }

    struct Fields: OptionSet, Sendable {
        let rawValue: Int
        /// Finder tags or the colour label.
        static let tags = Fields(rawValue: 1 << 0)
        /// The file's content or type: what the content index reads (mtime, dataless state, type, name).
        static let content = Fields(rawValue: 1 << 1)
        /// The row entered or left the library.
        static let membership = Fields(rawValue: 1 << 2)
    }

    /// More rows than this and the set says "everything" instead: a consumer would rebuild anyway, and
    /// a library nobody takes changes from must not grow a set without bound.
    static let rowLimit = 2_000

    /// By path (`ArchiveFile.path`, compared by bytes). nil: the whole library.
    private(set) var rows: [UTF8Key: Row]? = [:]
    /// `ArchiveLibrary.filesRevision` when the set began and when it was taken: the rows' `old` values are
    /// the library at `fromRevision`, their `new` values the library at `toRevision`.
    var fromRevision: UInt64 = 0
    var toRevision: UInt64 = 0

    var isEmpty: Bool { rows?.isEmpty ?? false }
    var isWhole: Bool { rows == nil }

    mutating func markWhole() { rows = nil }

    /// Record one row's change. Repeated changes to a path keep its first `old` and its last `new`; a row
    /// that comes back to what it was is still recorded, since its provenance and read time moved.
    mutating func record(path: String, old: ArchiveFile?, new: ArchiveFile?) {
        guard rows != nil else { return }
        let key = UTF8Key(path)
        if let earlier = rows![key] {
            if earlier.old == nil, new == nil { rows![key] = nil } else { rows![key]!.new = new }
        } else {
            rows![key] = Row(old: old, new: new)
        }
        if rows!.count > Self.rowLimit { rows = nil }
    }

    /// The fields that differ for one row.
    static func fields(_ row: Row) -> Fields {
        guard let old = row.old, let new = row.new else { return .membership }
        var fields: Fields = []
        if old.tags != new.tags { fields.insert(.tags) }
        if old.contentModified != new.contentModified || old.isDataless != new.isDataless
            || old.fileType != new.fileType || old.name != new.name || old.url != new.url {
            fields.insert(.content)
        }
        return fields
    }

    /// Every field any row changed; `.membership`, `.content` and `.tags` all set for a whole-library change.
    var fields: Fields {
        guard let rows else { return [.tags, .content, .membership] }
        return rows.values.reduce(into: Fields()) { $0.formUnion(Self.fields($1)) }
    }
}

/// Where each row of `ArchiveLibrary.files` is, and which paths are folders of some row, so a change to one
/// path finds its row without touching the others. Built once per whole-library publish (off the main actor
/// when there is time), kept through in-place row replacements, and dropped when rows are added or removed.
struct LibraryRowIndex: Sendable {
    let positions: [UTF8Key: Int]
    /// Every proper ancestor folder of every row, by bytes: a path in here has rows under it.
    let folders: Set<UTF8Key>

    init(_ files: [ArchiveFile]) {
        var positions: [UTF8Key: Int] = [:]
        positions.reserveCapacity(files.count)
        var folders = Set<UTF8Key>()
        for (i, file) in files.enumerated() {
            positions[UTF8Key(file.path)] = i
            var path = file.path
            while let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")) {
                path = String(path[..<slash])
                if path.isEmpty || !folders.insert(UTF8Key(path)).inserted { break }
            }
        }
        self.positions = positions
        self.folders = folders
    }

    func position(of path: String) -> Int? { positions[UTF8Key(path)] }
    func hasRows(under path: String) -> Bool { folders.contains(UTF8Key(path)) }
}
