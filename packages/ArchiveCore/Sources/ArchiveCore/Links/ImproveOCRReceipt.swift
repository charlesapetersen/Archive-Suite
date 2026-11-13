// ImproveOCRReceipt.swift — the Processor's record that a file's text was replaced, for the Reader (ArchiveCore)
//
// `execution-plans/reocr/00-plan.md` §7. Written to `<shared support>/Receipts/<operation UUID>.json` once a
// replacement is published and verified, independently of whether the flag could be cleared. The Reader reads it on
// launch, root activation or a wake-up hint, checks it against its own granted root and the file's current bytes,
// re-extracts the text and acknowledges it. A receipt carries no OCR text and no credentials, and grants no access:
// it names a file by root GUID and relative path only.
import Foundation

public struct ImproveOCRReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// The new text pages are in place.
        case published
        /// An earlier publication was undone; the old text is back.
        case restored
    }

    public let operationID: UUID
    public let rootGUID: UUID
    public let relativePath: String
    /// The replaced text pages, 0-based page indices.
    public let textPages: [Int]
    public let beforeSHA256: String
    public let afterSHA256: String
    public let outcome: Outcome
    public let date: Date

    public init(operationID: UUID, key: ImproveOCRFlagStore.FileKey, textPages: [Int], beforeSHA256: String,
                afterSHA256: String, outcome: Outcome, date: Date = Date()) {
        self.operationID = operationID
        self.rootGUID = key.rootGUID
        self.relativePath = key.relativePath
        self.textPages = textPages.sorted()
        self.beforeSHA256 = beforeSHA256
        self.afterSHA256 = afterSHA256
        self.outcome = outcome
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    public static let folder = "Receipts"

    public static func url(for operationID: UUID, in support: URL) -> URL {
        support.appendingPathComponent(folder, isDirectory: true).appendingPathComponent("\(operationID.uuidString).json")
    }

    /// Publishes the receipt once, whole (a synced temporary linked into place). Writing the same receipt again is a
    /// no-op; a different receipt under the same operation is refused.
    public func write(to support: URL) throws {
        let store = ImproveOCRFlagStore(support: support)
        try store.checkSuitable()
        try ImproveOCRFlagStore.makePrivateFolder(support.appendingPathComponent(Self.folder, isDirectory: true))
        let url = Self.url(for: operationID, in: support)
        if FileManager.default.fileExists(atPath: url.path) {
            guard let existing = try? Self.read(url), existing.sameRevision(as: self) else {
                throw ImproveOCRFlagStore.StoreError.io("a different receipt exists for \(operationID)")
            }
            return
        }
        try ImproveOCRFlagStore.createExclusive(url, ImproveOCRFlagStore.encode(self))
    }

    /// Everything but the date: a retry or a rebuilt receipt for the same revision is the same receipt.
    public func sameRevision(as other: ImproveOCRReceipt) -> Bool {
        operationID == other.operationID && rootGUID == other.rootGUID && relativePath == other.relativePath
            && textPages == other.textPages && beforeSHA256 == other.beforeSHA256 && afterSHA256 == other.afterSHA256
            && outcome == other.outcome
    }

    public static func read(_ url: URL) throws -> ImproveOCRReceipt {
        try ImproveOCRFlagStore.decode(ImproveOCRReceipt.self, from: url)
    }
}
