import Foundation
import ArchiveCore

// MARK: - Improve OCR: the Processor's receipts, read by the Reader (W44.reocr-reader)

/// The Processor writes `Receipts/<operation UUID>.json` in the shared folder each time it puts new text pages in a
/// file, or restores the old ones (`SPEC/improve-ocr.md` §4). It keeps the file's modification date, so the Reader's
/// index would never notice; the receipt is how it learns. A receipt grants nothing: the Reader finds the file among
/// its own library's rows (inside its granted root) by the receipt's archive and relative path, re-reads it as it is
/// now (a later change wins over a stale receipt), and records the receipt as seen in its own defaults. It never
/// writes or removes a receipt.
struct ImproveOCRReceiptInbox {
    let defaults: UserDefaults
    /// Every receipt ID seen, uncapped: a receipt forgotten from a capped list would be read again, and its file
    /// re-indexed, at every check (one per accepted or restored file, so this stays small).
    static let seenKey = "ImproveOCR.seenReceipts"

    /// What one receipt means for this archive.
    enum Disposition: Equatable {
        /// The library row to read again.
        case refresh(String)
        /// Nothing to do, ever (the file is gone from this archive, or the receipt names no valid path): mark it seen.
        case drop
        /// Not for this library now (another archive, a file not listed yet, a receipt this build cannot read):
        /// leave it unseen and do not look at it again until the library changes.
        case notHere
    }

    /// The receipts not yet seen, oldest first, leaving out `skipping` before anything is decoded.
    func unseen(in support: URL, skipping: Set<UUID>) -> [(id: UUID, receipt: ImproveOCRReceipt?)] {
        let folder = support.appendingPathComponent(ImproveOCRReceipt.folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        var found: [(id: UUID, receipt: ImproveOCRReceipt?, date: Date)] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !seen.contains(id.uuidString),
                  !skipping.contains(id) else { continue }
            var receipt = try? ImproveOCRReceipt.read(folder.appendingPathComponent(name))
            if receipt?.operationID != id { receipt = nil }
            found.append((id, receipt, receipt?.date ?? .distantPast))
        }
        return found.sorted { $0.date < $1.date }.map { ($0.id, $0.receipt) }
    }

    /// Which library row `receipt` names. `rows` are the library's paths with their NFC spelling, built once per
    /// check: the row is matched by its normalized tail and then by its full key (archive GUID and relative path, as
    /// both apps compute it), so a symlinked root or a decomposed file name still finds the row the index uses.
    static func disposition(of receipt: ImproveOCRReceipt?, archive: ImproveOCRArchive,
                            rows: () -> [(path: String, nfc: String)]) -> Disposition {
        guard let receipt else { return .notHere }
        guard ImproveOCRPath.problem(receipt.relativePath) == nil else { return .drop }
        guard let granted = archive.rootURL else { return .notHere }
        let relative = receipt.relativePath.precomposedStringWithCanonicalMapping
        let tail = "/" + relative
        for row in rows() where row.nfc.hasSuffix(tail) {
            let url = URL(fileURLWithPath: row.path)
            if case .root(let r) = archive.root(for: url), r.guid == receipt.rootGUID,
               let key = try? ImproveOCRFlagStore.FileKey(rootGUID: r.guid, root: r.url, file: url),
               key.relativePath == relative {
                return .refresh(row.path)
            }
        }
        // No row: gone for good only when this is the receipt's archive and the file is not there.
        if (try? RootMarker.read(at: granted))??.guid == receipt.rootGUID,
           !FileManager.default.fileExists(atPath: granted.appendingPathComponent(receipt.relativePath).path) {
            return .drop
        }
        return .notHere
    }

    func markSeen(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        seen += ids.map(\.uuidString)
        defaults.set(seen, forKey: Self.seenKey)
    }
}

/// Posted on the main thread with the paths whose contents an Improve OCR receipt says were replaced; a document
/// window showing one loads it again.
enum ReaderFileContentsReplaced {
    static let pathsKey = "paths"
}

extension Notification.Name {
    static let readerFileContentsReplaced = Notification.Name("com.archivereader.fileContentsReplaced")
}
