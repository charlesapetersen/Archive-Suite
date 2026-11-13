import Foundation
import ArchiveCore

// MARK: - Improve OCR: the Processor's receipts, read by the Reader (W44.reocr-reader)

/// The Processor writes `Receipts/<operation UUID>.json` in the shared folder each time it puts new text pages in a
/// file, or restores the old ones (`SPEC/improve-ocr.md` §4). It keeps the file's modification date, so the Reader's
/// index would never notice; the receipt is how it learns. A receipt grants nothing: the Reader finds the file inside
/// its own granted root by the receipt's archive and relative path, re-reads it as it is now (a later change wins
/// over a stale receipt), and records the receipt as seen in its own defaults. It never writes or removes a receipt.
struct ImproveOCRReceiptInbox {
    let defaults: UserDefaults
    static let seenKey = "ImproveOCR.seenReceipts"
    /// Receipt IDs kept as seen; the oldest go first past this.
    static let seenLimit = 5000

    /// What one receipt means for this archive.
    enum Disposition: Equatable {
        /// The file to read again, by its path inside the granted root.
        case refresh(String)
        /// Nothing to do here (the file is gone, or the receipt cannot be read): mark it seen.
        case drop
        /// Another archive's receipt: leave it for when that archive is open.
        case notHere
    }

    /// The receipts not yet seen, oldest first.
    func unseen(in support: URL) -> [(id: UUID, receipt: ImproveOCRReceipt?)] {
        let folder = support.appendingPathComponent(ImproveOCRReceipt.folder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let seen = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
        var found: [(id: UUID, receipt: ImproveOCRReceipt?, date: Date)] = []
        for name in names where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !seen.contains(id.uuidString) else { continue }
            let receipt = try? ImproveOCRReceipt.read(folder.appendingPathComponent(name))
            if let receipt, receipt.operationID != id { found.append((id, nil, .distantPast)); continue }
            found.append((id, receipt, receipt?.date ?? .distantPast))
        }
        return found.sorted { $0.date < $1.date }.map { ($0.id, $0.receipt) }
    }

    /// Where `receipt`'s file is in this archive. `candidates` are the library's paths, searched only when the
    /// receipt's archive is a marked folder below the granted root.
    static func disposition(of receipt: ImproveOCRReceipt?, archive: ImproveOCRArchive,
                            candidates: () -> [String]) -> Disposition {
        guard let receipt, ImproveOCRPath.problem(receipt.relativePath) == nil else { return .drop }
        guard let granted = archive.rootURL else { return .notHere }
        func inArchive(_ path: String) -> Bool {
            if case .root(let r) = archive.root(for: URL(fileURLWithPath: path)), r.guid == receipt.rootGUID,
               let key = try? ImproveOCRFlagStore.FileKey(rootGUID: r.guid, root: r.url, file: URL(fileURLWithPath: path)) {
                return key.relativePath == receipt.relativePath.precomposedStringWithCanonicalMapping
            }
            return false
        }
        // The usual case: the archive is the granted folder itself.
        if (try? RootMarker.read(at: granted))??.guid == receipt.rootGUID {
            let path = granted.appendingPathComponent(receipt.relativePath).path
            guard FileManager.default.fileExists(atPath: path) else { return .drop }
            return inArchive(path) ? .refresh(path) : .drop
        }
        let tail = "/" + receipt.relativePath
        let matches = candidates().filter { $0.hasSuffix(tail) && inArchive($0) }
        if let path = matches.first { return .refresh(path) }
        return .notHere
    }

    func markSeen(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var seen = defaults.stringArray(forKey: Self.seenKey) ?? []
        seen += ids.map(\.uuidString)
        if seen.count > Self.seenLimit { seen.removeFirst(seen.count - Self.seenLimit) }
        defaults.set(seen, forKey: Self.seenKey)
    }
}

/// Posted on the main thread with the paths whose contents an Improve OCR receipt says were replaced; an open
/// document window showing one loads it again.
enum ReaderFileContentsReplaced {
    static let pathsKey = "paths"
}

extension Notification.Name {
    static let readerFileContentsReplaced = Notification.Name("com.archivereader.fileContentsReplaced")
}
