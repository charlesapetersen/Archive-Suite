import Foundation
import ArchiveCore

// MARK: - Improve OCR: the Reader's connection to the shared support folder (W44.reocr-reader)

/// The Reader's own saved connection to the Improve OCR shared support folder (`SPEC/improve-ocr.md` §1): a
/// security-scoped bookmark to the folder the person chose in the Reader's panel, and the folder's identity
/// (`ImproveOCRSupportIdentity`) as it was when connected. Every use resolves the bookmark and checks that identity
/// again, so a moved, replaced or different folder is reported ("reconnect") instead of silently keeping a second set
/// of flags. The Processor keeps its own connection; the folder grants nothing over an archive, and connecting it
/// never touches the archive root or its bookmark.
///
/// Thread-safe: the tag writer reads it from whichever thread writes.
final class ImproveOCRSupport: @unchecked Sendable {
    static let shared = ImproveOCRSupport(defaults: ImproveOCRSupport.defaultStore())

    static let bookmarkKey = "ImproveOCR.supportBookmark"
    static let storeIDKey = "ImproveOCR.supportStoreID"

    enum Problem: Error, Equatable, CustomStringConvertible {
        case notConnected
        case unavailable(String)
        case differentStore

        var description: String {
            switch self {
            case .notConnected: "Connect the Improve OCR folder first (Tags ▸ Connect Improve OCR Folder…)"
            case .unavailable(let why): "The Improve OCR folder cannot be used (\(why)); reconnect it"
            case .differentStore: "The Improve OCR folder is not the one connected before; reconnect it"
            }
        }
    }

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// The folder whose security scope this process holds, released when another replaces it.
    private var scoped: URL?

    init(defaults: UserDefaults) { self.defaults = defaults }

    /// The unit-test host and a UITest launch keep their connection apart from the person's: both run as
    /// `com.archivereader.app` and would otherwise share its defaults.
    static func defaultStore() -> UserDefaults {
        if ArchiveTestHost.isUnitTestHost || ProcessInfo.processInfo.arguments.contains("-ARUITestRootPath") {
            return UserDefaults(suiteName: "com.archivereader.app.improveocr-test") ?? .standard
        }
        return .standard
    }

    /// Whether a folder was ever connected (it may still fail to resolve).
    var isConnected: Bool { defaults.data(forKey: Self.bookmarkKey) != nil }

    /// Connects `folder` (chosen in the Reader's panel, so the sandbox has granted it): makes its identity when it
    /// has none, and saves a security-scoped bookmark and the identity.
    @discardableResult
    func connect(_ folder: URL) throws -> URL {
        let id: UUID
        do {
            guard let made = try ImproveOCRSupportIdentity.identity(of: folder, create: true) else {
                throw Problem.unavailable("it has no store record")
            }
            id = made
        } catch let p as Problem { throw p } catch { throw Problem.unavailable(Self.describe(error)) }
        let bookmark: Data
        do { bookmark = try folder.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw Problem.unavailable(Self.describe(error)) }
        lock.withLock {
            defaults.set(bookmark, forKey: Self.bookmarkKey)
            defaults.set(id.uuidString, forKey: Self.storeIDKey)
        }
        return try resolve()
    }

    /// The connected folder, checked: the bookmark resolves (a stale one is renewed), its scope is held, the folder
    /// is still suitable, and it is the same store as when connected.
    func resolve() throws -> URL {
        try lock.withLock {
            guard let bookmark = defaults.data(forKey: Self.bookmarkKey),
                  let saved = defaults.string(forKey: Self.storeIDKey).flatMap(UUID.init(uuidString:)) else {
                throw Problem.notConnected
            }
            var stale = false
            let url: URL
            do {
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch { throw Problem.unavailable(Self.describe(error)) }
            if scoped?.standardizedFileURL != url.standardizedFileURL {
                scoped?.stopAccessingSecurityScopedResource()
                scoped = url.startAccessingSecurityScopedResource() ? url : nil
            }
            let id: UUID?
            do { id = try ImproveOCRSupportIdentity.identity(of: url, create: false) }
            catch { throw Problem.unavailable(Self.describe(error)) }
            guard let id else { throw Problem.unavailable("it has no store record") }
            guard id == saved else { throw Problem.differentStore }
            if stale, let renewed = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                defaults.set(renewed, forKey: Self.bookmarkKey)
            }
            return url
        }
    }

    func disconnect() {
        lock.withLock {
            scoped?.stopAccessingSecurityScopedResource()
            scoped = nil
            defaults.removeObject(forKey: Self.bookmarkKey)
            defaults.removeObject(forKey: Self.storeIDKey)
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? ImproveOCRFlagStore.StoreError {
            switch e {
            case .unsuitableFolder(let why): return why
            case .notPrivate: return "its folders are open to other users"
            case .busy: return "another app is changing this file's OCR Poor flag"
            case .io(let why): return why
            default: return "\(e)"
            }
        }
        return error.localizedDescription
    }
}

/// The archive the tag writer's poor-OCR guard keys files by: the main root and its marker's GUID. Set by the
/// navigation model when a root is granted; read on any thread.
final class ImproveOCRArchive: @unchecked Sendable {
    static let shared = ImproveOCRArchive()

    struct Root: Equatable, Sendable {
        let url: URL
        /// Nil while the folder has no readable root marker (a read-only folder, or a damaged marker).
        let guid: UUID?
    }

    private let lock = NSLock()
    private var _root: URL?

    /// The main archive root, or nil when none is granted.
    var rootURL: URL? {
        get { lock.withLock { _root } }
        set { lock.withLock { _root = newValue } }
    }

    /// The root with its marker read now: the marker can appear after the folder was chosen (a link copy creates one).
    func current() -> Root? {
        guard let url = rootURL else { return nil }
        return Root(url: url, guid: (try? RootMarker.read(at: url))??.guid)
    }
}
