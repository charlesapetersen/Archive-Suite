// ImproveOCRSupportIdentity.swift — which shared support folder this is, for Improve OCR (ArchiveCore)
//
// `execution-plans/reocr/00-plan.md` §3. The Reader and the Processor each connect the shared support folder through
// their own folder panel and keep their own bookmark. The folder's identity is a UUID in `store.json`, made once by
// whichever app connects first; each app saves it on connecting and checks it every time it resolves its bookmark,
// so two apps pointed at two different folders (or a folder replaced by a copy) refuse to coordinate instead of each
// keeping its own flags and receipts.
import Foundation

public enum ImproveOCRSupportIdentity {
    public static let file = "store.json"
    /// Where both apps suggest the folder; the panel may create it.
    public static var suggestedLocation: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArchiveSuite", isDirectory: true).appendingPathComponent("ImproveOCR", isDirectory: true)
    }

    struct Record: Codable, Equatable {
        let storeID: UUID
        let created: Date
    }

    /// The folder's identity, made now when `create` and there is none. Two apps creating at once agree: the file is
    /// published exclusively, and the one that loses reads the winner's.
    public static func identity(of support: URL, create: Bool) throws -> UUID? {
        try ImproveOCRFlagStore(support: support).checkSuitable()
        let url = support.appendingPathComponent(file)
        if let existing = try read(url) { return existing }
        guard create else { return nil }
        let record = Record(storeID: UUID(), created: ImproveOCRFlagStore.now())
        do {
            try ImproveOCRFlagStore.createExclusive(url, ImproveOCRFlagStore.encode(record))
            return record.storeID
        } catch {
            if let winner = try read(url) { return winner }
            throw error
        }
    }

    private static func read(_ url: URL) throws -> UUID? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ImproveOCRFlagStore.decode(Record.self, from: url).storeID
    }
}
