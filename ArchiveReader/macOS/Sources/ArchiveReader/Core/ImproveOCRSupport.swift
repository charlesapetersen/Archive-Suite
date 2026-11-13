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
            case .notConnected: "Connect the Improve OCR folder first (File ▸ Connect Improve OCR Folder…)"
            case .unavailable(let why): "The Improve OCR folder cannot be used (\(why)); reconnect it"
            case .differentStore: "The Improve OCR folder is not the one connected before; reconnect it"
            }
        }
    }

    /// Also holds the receipts the Reader has seen (`ImproveOCRReceiptInbox`).
    let defaults: UserDefaults
    private let lock = NSLock()
    /// The folder whose security scope this process holds, released when another replaces it.
    private var scoped: URL?

    /// DEBUG UITest launches only: a folder the test made, used by path (`-ARUITestImproveOCRSupport <path>`), since
    /// an off-screen run cannot answer a folder panel. Never a bookmark, never the person's defaults.
    private var testFolder: URL?

    init(defaults: UserDefaults) {
        self.defaults = defaults
#if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-ARUITestRootPath"), let i = args.firstIndex(of: "-ARUITestImproveOCRSupport"), i + 1 < args.count {
            testFolder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
#endif
    }

    /// The unit-test host and a UITest launch keep their connection apart from the person's: both run as
    /// `com.archivereader.app` and would otherwise share its defaults.
    static func defaultStore() -> UserDefaults {
        if ArchiveTestHost.isUnitTestHost || ProcessInfo.processInfo.arguments.contains("-ARUITestRootPath") {
            return UserDefaults(suiteName: "com.archivereader.app.improveocr-test") ?? .standard
        }
        return .standard
    }

    /// Where the folder panel opens: the suite's suggested folder in the person's own Library. Not
    /// `ImproveOCRSupportIdentity.suggestedLocation`, which in the sandboxed Reader names the app's container; the
    /// Processor is not sandboxed, and its suggestion is the real Library's.
    static func suggestedPanelLocation() -> URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        let support = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let suggested = support.appendingPathComponent("ArchiveSuite/ImproveOCR", isDirectory: true)
        return FileManager.default.fileExists(atPath: suggested.path) ? suggested : support
    }

    /// Whether a folder was ever connected (it may still fail to resolve).
    var isConnected: Bool { lock.withLock { testFolder != nil || defaults.data(forKey: Self.bookmarkKey) != nil } }

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
            if let testFolder {
                do {
                    guard try ImproveOCRSupportIdentity.identity(of: testFolder, create: true) != nil else {
                        throw Problem.unavailable("it has no store record")
                    }
                } catch let p as Problem { throw p } catch { throw Problem.unavailable(Self.describe(error)) }
                return testFolder
            }
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

/// The archive the poor-OCR flag records and the hand-off key files by: for each file, the nearest folder above it
/// that holds a root marker, searched no higher than the granted root (`SPEC/improve-ocr.md` §3). The Processor
/// finds a file's archive the same way, so a granted folder holding an older marked subfolder keys its files under
/// that subfolder in both apps. Set by the root store when a root is granted; read on any thread.
final class ImproveOCRArchive: @unchecked Sendable {
    static let shared = ImproveOCRArchive()

    struct Root: Equatable, Sendable {
        let url: URL
        let guid: UUID
    }

    enum Lookup: Equatable, Sendable {
        case root(Root)
        /// The file is not inside the granted root, or no root is granted.
        case outside
        /// No readable marker between the file and the granted root (a read-only folder, or a damaged marker).
        case noIdentity
    }

    private let lock = NSLock()
    private var _root: URL?

    /// The granted root, or nil when none is granted.
    var rootURL: URL? {
        get { lock.withLock { _root } }
        set { lock.withLock { _root = newValue } }
    }

    /// The archive `file` belongs to, read now: a marker can appear after the folder was chosen.
    func root(for file: URL) -> Lookup {
        guard let granted = rootURL?.standardizedFileURL.resolvingSymlinksInPath() else { return .outside }
        let top = granted.pathComponents
        var dir = file.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
        guard dir.pathComponents.count >= top.count, Array(dir.pathComponents.prefix(top.count)) == top else { return .outside }
        while dir.pathComponents.count >= top.count {
            switch Result(catching: { try RootMarker.read(at: dir) }) {
            case .success(let marker?): return .root(Root(url: dir, guid: marker.guid))
            case .success(nil): break
            case .failure: return .noIdentity   // a damaged marker is left alone, never looked past
            }
            dir.deleteLastPathComponent()
        }
        return .noIdentity
    }
}
