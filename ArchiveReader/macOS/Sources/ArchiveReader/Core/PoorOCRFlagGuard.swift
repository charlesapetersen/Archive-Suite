import Foundation
import ArchiveCore

// MARK: - Every Reader tag write that can change `OCR Poor` (W44.reocr-reader)
//
// `SPEC/improve-ocr.md` §3: each suite action that changes `OCR Poor` takes the file's flag lock, begins a new flag
// generation, changes the tag through the audited writer, and commits the value read back. In the Reader that is the
// Flag/Unflag command, and also any generic subject edit, rename, undo or redo whose delta names the tag, so a flag
// put back by hand during a re-read is never cleared by the Processor's acceptance. Lock first, then coordination:
// `TagWriter` calls this around its `CoordinatedTagWriter` write, never from inside it.
//
// When the Improve OCR folder was never connected, a generic edit goes ahead unrecorded, like an edit in Finder (the
// stated limit of a boolean tag); the Flag command itself refuses until it is connected. A connected folder that can
// no longer be used refuses every write that names the tag, with a reconnect message, rather than keep an unshared
// record. This file holds no write API: the flag store is ArchiveCore's, the tag write `TagWriter`'s.

enum PoorOCRFlagGuard {
    /// What a write that names the tag recorded, for the audit ledger (`AuditLedger.Entry.flag`).
    struct Record: Codable, Equatable, Sendable {
        var rootGUID: UUID
        var relativePath: String
        var operationID: UUID
        var generationBefore: UUID?
        /// Nil when the record could not be finished after the tag write (`finished` false).
        var generationAfter: UUID?
        var requested: Bool
        /// The tag as read back after the write; nil when it could not be read.
        var observed: Bool?
        /// False when the tag write happened but its flag record could not be committed: the record then holds the
        /// tag as it was found, or a barrier the next suite action on the file reconciles.
        var finished: Bool
        /// The text pages' Kind and reader when the action knew them; absent means unknown.
        var kind: String?
        var reader: String?
    }

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case support(String)
        case noArchiveIdentity
        case outsideArchive
        case busy
        case tagsUnreadable

        var description: String {
            switch self {
            case .support(let why): why
            case .noArchiveIdentity: "This archive folder has no identity file yet, so its OCR Poor flags cannot be recorded. Choose the folder again (File ▸ Choose Archive Folder…)."
            case .outsideArchive: "This file is outside the current archive folder."
            case .busy: "Another app is changing this file's OCR Poor flag. Try again in a moment."
            case .tagsUnreadable: "This file's tags cannot be read."
            }
        }
    }

    /// Kind and reader per file path, bound by the Flag command so the ledger can say what was flagged.
    @TaskLocal static var annotations: [String: (kind: String?, reader: String?)] = [:]

    /// Collects the files whose tag changed but whose flag record could not be finished, so the action can say so.
    final class Unfinished: @unchecked Sendable {
        private let lock = NSLock()
        private var _names: [String] = []
        var names: [String] { lock.withLock { _names } }
        func note(_ url: URL) { lock.withLock { _names.append(url.lastPathComponent) } }
    }
    @TaskLocal static var unfinished: Unfinished?

    /// The value a delta asks for: true when it adds the tag, false when it only removes it, nil when it does not
    /// name it (the write then needs no guard). Additions win, as in `TagWriter.apply`, which removes first.
    static func requested(add: [String], remove: [String]) -> Bool? {
        if add.contains(where: { isSameTag($0, DocumentTags.poorOCRTag) }) { return true }
        if remove.contains(where: { shouldRemoveTag(DocumentTags.poorOCRTag, matching: $0) }) { return false }
        return nil
    }

    /// Whether the file is flagged now, read from the disk; nil when its tags cannot be read.
    static func isFlagged(_ url: URL) -> Bool? {
        guard case let .success(names, _) = TagReading.read(url) else { return nil }
        return names.contains { isSameTag($0, DocumentTags.poorOCRTag) }
    }

    /// The flag store and key for `url`, or nil when no Improve OCR folder was ever connected.
    static func target(for url: URL, support: ImproveOCRSupport = .shared,
                       archive: ImproveOCRArchive = .shared) throws -> (store: ImproveOCRFlagStore, key: ImproveOCRFlagStore.FileKey)? {
        guard support.isConnected else { return nil }
        let folder: URL
        do { folder = try support.resolve() } catch { throw Refusal.support("\(error)") }
        let root: ImproveOCRArchive.Root
        switch archive.root(for: url) {
        case .root(let r): root = r
        case .outside: throw Refusal.outsideArchive
        case .noIdentity: throw Refusal.noArchiveIdentity
        }
        let key: ImproveOCRFlagStore.FileKey
        do { key = try ImproveOCRFlagStore.FileKey(rootGUID: root.guid, root: root.url, file: url) } catch { throw Refusal.outsideArchive }
        // A short wait on the main thread, where every Reader write runs today; the Processor holds the lock only
        // for its own tag write.
        return (ImproveOCRFlagStore(support: folder, lockTimeout: Thread.isMainThread ? 1 : 10), key)
    }

    /// Runs `write` under the flag protocol when `requested` is non-nil and a folder is connected; otherwise runs it
    /// as it is. `record` receives what was recorded.
    static func run<T>(requested: Bool?, url: URL, record: inout Record?, _ write: () throws -> T) throws -> T {
        guard let requested, let target = try target(for: url) else { return try write() }
        let app = "Archive Reader"
        var made: Record?
        let result: T
        do {
            result = try target.store.withLock(target.key, app: app) { locked -> T in
                var state = try locked.state()
                if state.isPending {
                    // An action that died before it finished (the lock is ours, so nothing else is running): record
                    // the tag as it is, which lifts the barrier.
                    guard let now = isFlagged(url) else { throw Refusal.tagsUnreadable }
                    try locked.reconcile(observedFlagged: now)
                    state = try locked.state()
                }
                let intent = try locked.begin(flagged: requested, origin: requested ? .flag : .unflag)
                let value: T
                do { value = try write() } catch {
                    // The barrier must not outlive this call: record what the tag is now (flagged when it cannot be
                    // read, so an acceptance never clears on a guess).
                    _ = try? locked.reconcile(observedFlagged: isFlagged(url) ?? true)
                    throw error
                }
                // The tags are on disk now. Nothing from here may make the write look refused: a record that cannot
                // be finished is reconciled if it can be, marked unfinished, and the write's result still returned.
                let observed = isFlagged(url)
                let event = observed.flatMap { try? locked.commit(intent, observedFlagged: $0) }
                if event == nil {
                    _ = try? locked.reconcile(observedFlagged: observed ?? true)
                    unfinished?.note(url)
                }
                let note = annotations[url.path]
                made = Record(rootGUID: target.key.rootGUID, relativePath: target.key.relativePath,
                              operationID: intent.operationID, generationBefore: state.generation,
                              generationAfter: event?.generation, requested: requested, observed: observed,
                              finished: event != nil, kind: note?.kind, reader: note?.reader)
                return value
            }
        } catch ImproveOCRFlagStore.StoreError.busy {
            throw Refusal.busy
        } catch let e as ImproveOCRFlagStore.StoreError {
            // Only the steps before the tag write throw these (the lock, the state, a reconcile, `begin`).
            throw Refusal.support(ImproveOCRSupport.Problem.unavailable(ImproveOCRSupport.describe(e)).description)
        }
        record = made
        return result
    }
}
