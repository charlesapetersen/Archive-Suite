import ArchiveCore
import Foundation

// MARK: - Improve OCR: the Processor's connection to the shared support folder (W44.reocr-processor)

/// The Processor's own saved connection to the shared support folder (`execution-plans/reocr/00-plan.md` §3): a
/// bookmark to the folder the person chose in the Processor's panel, and the folder's identity
/// (`ImproveOCRSupportIdentity`) as it was when connected. Every use resolves the bookmark and checks that identity
/// again, so a moved, replaced or different folder is reported ("reconnect") instead of silently starting a second
/// set of flags and receipts. The Reader keeps its own connection; the shared folder grants nothing over an archive.
struct ReOCRSupportConnection {
    let defaults: UserDefaults

    static let bookmarkKey = "ImproveOCR.supportBookmark"
    static let storeIDKey = "ImproveOCR.supportStoreID"

    struct Connected: Equatable, Sendable {
        let url: URL
        let storeID: UUID
    }

    enum Problem: Error, Equatable, CustomStringConvertible {
        case notConnected
        case unavailable(String)
        case differentStore

        var description: String {
            switch self {
            case .notConnected: "Improve OCR needs its shared folder: connect it in the Processor first"
            case .unavailable(let why): "the Improve OCR shared folder cannot be used (\(why)); reconnect it"
            case .differentStore: "the Improve OCR shared folder is not the one connected before; reconnect it"
            }
        }
    }

    /// Connects `folder` (chosen in the panel): makes its identity if it has none, and saves the bookmark and identity.
    func connect(_ folder: URL) throws -> Connected {
        let id: UUID
        do {
            guard let made = try ImproveOCRSupportIdentity.identity(of: folder, create: true) else { throw Problem.unavailable("no identity") }
            id = made
        } catch let p as Problem { throw p } catch { throw Problem.unavailable("\(error)") }
        let bookmark: Data
        do { bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw Problem.unavailable("\(error)") }
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        defaults.set(id.uuidString, forKey: Self.storeIDKey)
        return Connected(url: folder, storeID: id)
    }

    /// The connected folder, checked: the bookmark resolves (a stale one is renewed), the folder is still suitable, and
    /// it is the same store as when connected.
    func resolve() throws -> Connected {
        guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
              let saved = defaults.string(forKey: Self.storeIDKey).flatMap(UUID.init(uuidString:)) else {
            throw Problem.notConnected
        }
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch { throw Problem.unavailable("\(error)") }
        let id: UUID?
        do { id = try ImproveOCRSupportIdentity.identity(of: url, create: false) } catch { throw Problem.unavailable("\(error)") }
        guard let id else { throw Problem.unavailable("it has no store record") }
        guard id == saved else { throw Problem.differentStore }
        if stale, let renewed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(renewed, forKey: Self.bookmarkKey)
        }
        return Connected(url: url, storeID: id)
    }

    func disconnect() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.storeIDKey)
    }
}
