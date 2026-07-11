import Foundation

/// Reference to a persisted note on disk (Sendable for cross-actor transport).
struct ItemRef: Sendable {
    let id: UUID
    let url: URL
    let mtime: Double
}

/// The single persistence layer for Archive Notes' UUID-folder store.
///
/// Every note lives in `<root>/items/<uuid>/<Title>.md` with an optional `assets/` subfolder.
/// All filesystem mutation is confined to this actor (Swift 6 safe). The resolved `root` URL
/// must already have its security scope started by `RootFolderStore` before use.
///
/// **Delete contract:** `delete` moves the item dir to Trash (recoverable). The
/// delete-last-membership guard (00-overview section 3.6) is enforced by the caller (W6 UI),
/// not here -- this is the low-level primitive that assumes the guard already passed.
actor NoteStore {

    enum StoreError: Error, Sendable {
        case rootUnavailable
        case corruptRootMarker
        case titleCollision(URL)
        case writeFailed(String)
        case notFound(UUID)
        case readFailed(String)
        case assetWriteFailed(String)
    }

    let root: URL

    init(root: URL) {
        self.root = root
    }

    // MARK: - Directory URLs (pure, no I/O)

    func itemDir(_ id: UUID) -> URL {
        root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func assetsDir(_ id: UUID) -> URL {
        itemDir(id).appendingPathComponent("assets", isDirectory: true)
    }

    // MARK: - CRUD

    func create(_ item: Item) throws -> ItemRef {
        let dir = itemDir(item.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDir(item.id), withIntermediateDirectories: true)

        let filename = Self.sanitizedTitle(item.title) + ".md"
        let fileURL = dir.appendingPathComponent(filename)

        let text = FrontMatterCodec.encode(item)
        try Data(text.utf8).write(to: fileURL, options: [.atomic])

        let mtime = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? Date().timeIntervalSinceReferenceDate
        return ItemRef(id: item.id, url: fileURL, mtime: mtime)
    }

    func load(_ id: UUID) throws -> Item {
        let url = try mdURL(for: id)
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw StoreError.readFailed("Cannot read \(url.lastPathComponent)")
        }
        do {
            return try FrontMatterCodec.decode(text)
        } catch {
            throw StoreError.readFailed("Parse failed for \(id): \(error)")
        }
    }

    func save(_ item: Item) throws -> ItemRef {
        let dir = itemDir(item.id)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(item.id)
        }

        let currentURL = try mdURL(for: item.id)
        let newFilename = Self.sanitizedTitle(item.title) + ".md"
        var targetURL = dir.appendingPathComponent(newFilename)

        // Rename if the title changed (filename is a projection of the title).
        if currentURL.lastPathComponent != newFilename {
            // Component-boundary guard: both URLs must be under this item's dir.
            precondition(currentURL.deletingLastPathComponent().standardizedFileURL ==
                         dir.standardizedFileURL,
                         "NoteStore: source URL escapes item dir")

            // Disambiguate intra-dir collision (defensive; one .md per dir by construction).
            if fm.fileExists(atPath: targetURL.path) {
                targetURL = Self.disambiguate(targetURL, in: dir)
            }

            try fm.moveItem(at: currentURL, to: targetURL)
        }

        // Write updated content atomically.
        let text = FrontMatterCodec.encode(item)
        try Data(text.utf8).write(to: targetURL, options: [.atomic])

        let mtime = (try? fm.attributesOfItem(atPath: targetURL.path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? Date().timeIntervalSinceReferenceDate
        return ItemRef(id: item.id, url: targetURL, mtime: mtime)
    }

    /// Move the item directory to the Trash (recoverable). Never `removeItem`.
    func delete(_ id: UUID) throws {
        let dir = itemDir(id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(id)
        }
        var resultURL: NSURL?
        try FileManager.default.trashItem(at: dir, resultingItemURL: &resultURL)
    }

    func allItemIDs() -> [UUID] {
        let itemsDir = root.appendingPathComponent("items", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: itemsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    func mdURL(for id: UUID) throws -> URL {
        let dir = itemDir(id)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            throw StoreError.notFound(id)
        }

        let mdFiles = entries.filter { $0.pathExtension == "md" }
        guard let first = mdFiles.first else {
            throw StoreError.notFound(id)
        }
        if mdFiles.count == 1 { return first }

        // Multiple .md files (manual meddling): prefer the one whose front-matter id matches.
        for url in mdFiles {
            if let data = FileManager.default.contents(atPath: url.path),
               let text = String(data: data, encoding: .utf8),
               let item = try? FrontMatterCodec.decode(text),
               item.id == id {
                return url
            }
        }
        // Fallback: lexicographically first.
        return mdFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first!
    }

    // MARK: - Assets

    func importAsset(_ data: Data, preferredName: String, into id: UUID) throws -> String {
        let dir = assetsDir(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var targetURL = dir.appendingPathComponent(preferredName)
        if fm.fileExists(atPath: targetURL.path) {
            targetURL = Self.disambiguateAsset(preferredName, in: dir)
        }

        do {
            try data.write(to: targetURL, options: [.atomic])
        } catch {
            throw StoreError.assetWriteFailed(error.localizedDescription)
        }
        return "assets/\(targetURL.lastPathComponent)"
    }

    // MARK: - Filename sanitization

    static func sanitizedTitle(_ title: String) -> String {
        var s = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // Trim leading/trailing whitespace and dots.
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))

        if s.isEmpty { s = "Untitled" }

        // Cap at ~200 UTF-16 units (APFS limit 255 bytes; headroom for .md + disambiguation).
        if s.utf16.count > 200 {
            let idx = s.utf16.index(s.utf16.startIndex, offsetBy: 200)
            s = String(s[..<idx])
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { s = "Untitled" }
        }

        return s
    }

    // MARK: - Disambiguation helpers

    private static func disambiguate(_ url: URL, in dir: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let fm = FileManager.default
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(stem) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    private static func disambiguateAsset(_ name: String, in dir: URL) -> URL {
        let nsName = name as NSString
        let stem = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        let fm = FileManager.default
        var n = 1
        while true {
            let candidate: URL
            if ext.isEmpty {
                candidate = dir.appendingPathComponent("\(stem)-\(n)")
            } else {
                candidate = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
            }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
