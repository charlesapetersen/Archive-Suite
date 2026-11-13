import Foundation

// MARK: - Improve OCR: the history of kept versions (W44.reocr-processor)

/// What Improve OCR has kept (`execution-plans/reocr/00-plan.md` §5): one entry per operation under `Versions/`, with
/// its file, date, what happened and how much it keeps. Kept copies stay until the person removes them here; nothing
/// expires on its own. Restore is `ReOCRJob.restore`; removal deletes only that operation's own kept copy and records.
struct ReOCRHistory {
    let writer: ReOCRFileWriter

    struct Entry: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            /// The new text is in place; the old file is kept and can be put back.
            case accepted
            /// A restore: the text an acceptance replaced is back; the accepted revision is kept.
            case restoredEarlier(UUID)
            /// An acceptance a later restore undid.
            case undone(by: UUID)
            case rejected
            /// Read but not decided (its review was closed or the app quit); removing it records it rejected.
            case undecided
            /// Stopped during publication; launch recovery settles it before it can be removed.
            case interrupted
            /// Its record cannot be read.
            case unreadable
        }

        let id: UUID
        let file: URL
        let date: Date
        let state: State
        /// Bytes this operation keeps (the copy of the file it replaced, and its records).
        let bytes: Int64

        var canRestore: Bool { state == .accepted }
        /// A decided operation's kept copy may be removed; an undecided one belongs to a review still open.
        var canRemove: Bool {
            switch state {
            case .accepted, .restoredEarlier, .undone, .rejected, .unreadable, .undecided: true
            case .interrupted: false
            }
        }
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case notRemovable
        case removeFailed(String)
        var description: String {
            switch self {
            case .notRemovable: "this change was stopped during publication; relaunch the Processor to settle it first"
            case .removeFailed(let why): "the kept copy could not be removed (\(why))"
            }
        }
    }

    /// Newest first.
    func entries() -> [Entry] {
        let root = writer.versionsRoot
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).compactMap(UUID.init(uuidString:))
        return ids.map { id -> Entry in
            let folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let size = Self.size(of: folder)
            guard let journal = try? writer.read(id) else {
                return Entry(id: id, file: folder, date: .distantPast, state: .unreadable, bytes: size)
            }
            let record = try? writer.readRecord(ReOCRJob.Record.self, named: ReOCRJob.Record.file, for: id)
            let state: Entry.State
            switch journal.phase {
            case .rejected: state = .rejected
            case .prepared: state = .undecided
            case .acceptReady: state = .interrupted
            case .published:
                if let restores = record?.restores { state = .restoredEarlier(restores) }
                else if let by = record?.restoredBy { state = .undone(by: by) }
                else { state = .accepted }
            }
            return Entry(id: id, file: URL(fileURLWithPath: journal.targetPath), date: journal.created, state: state, bytes: size)
        }
        .sorted { $0.date > $1.date }
    }

    var totalBytes: Int64 { entries().reduce(0) { $0 + $1.bytes } }

    /// Removes one decided operation's kept copy and records: after this its text can no longer be put back from here.
    func remove(_ id: UUID) throws {
        guard let entry = entries().first(where: { $0.id == id }), entry.canRemove else { throw Failure.notRemovable }
        if entry.state == .undecided, let journal = try? writer.read(id) {
            try? writer.reject(ReOCRFileWriter.Operation(journal: journal))
        }
        let folder = writer.versionsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        do { try FileManager.default.removeItem(at: folder) } catch { throw Failure.removeFailed("\(error)") }
    }

    private static func size(of folder: URL) -> Int64 {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.reduce(Int64(0)) { total, name in
            var st = stat()
            return lstat(folder.appendingPathComponent(name).path, &st) == 0 ? total + Int64(st.st_size) : total
        }
    }
}
