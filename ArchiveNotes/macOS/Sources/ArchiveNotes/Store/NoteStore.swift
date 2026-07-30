import Foundation

/// Reference to a persisted note on disk (Sendable for cross-actor transport).
struct ItemRef: Sendable {
    let id: UUID
    let url: URL
    let mtime: Double
}

/// The outcome of one atomic item transaction (`NoteStore.withItem`/`withTemplate`): the item
/// exactly as it was written, plus its on-disk ref. Callers index/publish `item` rather than
/// re-reading the store, so what they show is what landed.
struct ItemTransaction: Sendable {
    let item: Item
    let ref: ItemRef
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

    /// The store's root URL. Immutable + `Sendable`, so it is safe to read synchronously off-actor —
    /// the @MainActor `ItemAssetStore` (W7-S5) reads it to derive `assets/` paths without an actor hop.
    nonisolated var rootURL: URL { root }

    /// Pure path math for an item's dir / assets dir, exposed `nonisolated static` so the @MainActor
    /// `ItemAssetStore` can compute the *same* paths this actor writes to — keeping the on-disk layout a
    /// single source of truth (no divergence between the synchronous asset-name reservation and the
    /// actor's byte write).
    nonisolated static func itemDir(root: URL, id: UUID) -> URL {
        root.appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    nonisolated static func assetsDir(root: URL, id: UUID) -> URL {
        itemDir(root: root, id: id).appendingPathComponent("assets", isDirectory: true)
    }

    func itemDir(_ id: UUID) -> URL { Self.itemDir(root: root, id: id) }

    func assetsDir(_ id: UUID) -> URL { Self.assetsDir(root: root, id: id) }

    /// Templates area (00-overview §3.7): `<root>/Templates/<uuid>/<Name>.md`, parallel to `items/`.
    /// Kept separate so templates never leak into the note list / All Notes count / FTS index.
    func templatesDir() -> URL {
        root.appendingPathComponent("Templates", isDirectory: true)
    }

    func templateDir(_ id: UUID) -> URL {
        templatesDir().appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    // MARK: - CRUD (notes — thin wrappers over the container-generic workers)

    func create(_ item: Item) throws -> ItemRef { try createEntry(item, in: itemDir(item.id)) }
    func load(_ id: UUID) throws -> Item { try loadEntry(id, in: itemDir(id)) }

    /// Whole-item overwrite. ⚠️ **W23.h2 — to EDIT an existing item, use `withItem` instead.** Pairing
    /// `load` with `save` re-opens the lost-update window this store now closes: the save writes the
    /// *whole* item, so it silently discards every field a concurrent edit changed in between. This
    /// primitive is for callers that already hold the authoritative item (tests, a full re-write).
    func save(_ item: Item) throws -> ItemRef { try saveEntry(item, in: itemDir(item.id)) }

    /// Move the item directory to the Trash (recoverable). Never `removeItem`.
    func delete(_ id: UUID) throws { try deleteEntry(id, in: itemDir(id)) }

    // MARK: - Atomic edit transactions (W23.h2)
    //
    // `load` + `save` are two SEPARATE actor calls, so a caller that spells its edit out as
    // load → mutate → save has a suspension point in the middle: two tasks can both load the same
    // old item, apply different edits, and save in either order, and the later whole-item save
    // silently drops the other's body, metadata or source blocks. (Measured before the fix: 24
    // concurrent same-item appends left exactly ONE survivor.) `@MainActor` does not help — it is
    // reentrant at every `await`.
    //
    // `withItem` makes the TRANSACTION the unit of serialization: the whole read-modify-write runs
    // inside one actor-isolated call, and because `mutate` is **synchronous** there is no suspension
    // point between the read and the write — no other transaction can interleave. Prefer it over
    // `load` + `save` for every edit to an existing item; a bare `load`/`save` pair is now only for
    // read-only reads and whole-item replacements that do not depend on prior on-disk state.

    /// Atomically load → mutate → save one note. `mutate` sees the CURRENT on-disk item (never a
    /// caller's stale copy) and must be synchronous, which is what makes the transaction atomic —
    /// do the async part (asset copies, parsing, clock reads) *before* the call and capture the
    /// result. A throwing `mutate` aborts the transaction and leaves the `.md` untouched.
    func withItem(_ id: UUID,
                  _ mutate: @Sendable (inout Item) throws -> Void) throws -> ItemTransaction {
        try withEntry(id, in: itemDir(id), mutate)
    }

    /// `withItem` for a template (same atomicity, `Templates/<uuid>/` container).
    func withTemplate(_ id: UUID,
                      _ mutate: @Sendable (inout Item) throws -> Void) throws -> ItemTransaction {
        try withEntry(id, in: templateDir(id), mutate)
    }

    /// The atomic load→mutate→save worker behind `withItem` / `withTemplate`. **Do not add an `await`
    /// to this function** — its atomicity IS the absence of a suspension point between the read and the
    /// write, so one `await` here silently re-opens W23.h2 with no test failing anywhere obvious.
    private func withEntry(_ id: UUID, in dir: URL,
                           _ mutate: (inout Item) throws -> Void) throws -> ItemTransaction {
        var item = try loadEntry(id, in: dir)
        try mutate(&item)
        let ref = try saveEntry(item, in: dir)
        return ItemTransaction(item: item, ref: ref)
    }

    func allItemIDs() -> [UUID] {
        let itemsDir = root.appendingPathComponent("items", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: itemsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    func mdURL(for id: UUID) throws -> URL { try mdURL(for: id, in: itemDir(id)) }

    /// Every on-disk item as an `ItemRef` (id + `.md` URL + mtime) for a full index (re)build. Items
    /// whose `.md` can't be located are skipped (best-effort, like `allTemplates`). The mtime uses the
    /// same `timeIntervalSinceReferenceDate` convention `createEntry` / `saveEntry` stamp, so the
    /// indexer's mtime skip-map (`NotesIndex.existingMTimes`) compares like-for-like.
    func allItemRefs() -> [ItemRef] {
        var refs: [ItemRef] = []
        for id in allItemIDs() {
            guard let url = try? mdURL(for: id) else { continue }
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
                .timeIntervalSinceReferenceDate ?? 0
            refs.append(ItemRef(id: id, url: url, mtime: mtime))
        }
        return refs
    }

    // MARK: - CRUD (templates — same primitives, stored under Templates/)

    func createTemplate(_ item: Item) throws -> ItemRef { try createEntry(item, in: templateDir(item.id)) }
    func loadTemplate(_ id: UUID) throws -> Item { try loadEntry(id, in: templateDir(id)) }
    /// Whole-template overwrite — see `save`'s warning; to EDIT a template use `withTemplate`.
    func saveTemplate(_ item: Item) throws -> ItemRef { try saveEntry(item, in: templateDir(item.id)) }

    /// Move the template directory to the Trash (recoverable). Never `removeItem`.
    func deleteTemplate(_ id: UUID) throws { try deleteEntry(id, in: templateDir(id)) }

    /// Every template on disk, projected to `Template` (id / name=title / kind) by decoding each
    /// `Templates/<uuid>/<Name>.md`. Unreadable entries are skipped (best-effort listing). Sorted by
    /// localized name for stable menu/list order.
    func allTemplates() -> [Template] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: templatesDir(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [Template] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let item = try? loadEntry(id, in: dir) else { continue }
            result.append(Template(id: item.id, name: item.title, kind: item.kind))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Container-generic workers (shared by notes + templates)

    private func createEntry(_ item: Item, in dir: URL) throws -> ItemRef {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("assets", isDirectory: true),
                               withIntermediateDirectories: true)

        let filename = Self.sanitizedTitle(item.title) + ".md"
        let fileURL = dir.appendingPathComponent(filename)

        let text = FrontMatterCodec.encode(item)
        try Data(text.utf8).write(to: fileURL, options: [.atomic])

        let mtime = (try? fm.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate ?? Date().timeIntervalSinceReferenceDate
        return ItemRef(id: item.id, url: fileURL, mtime: mtime)
    }

    private func loadEntry(_ id: UUID, in dir: URL) throws -> Item {
        let url = try mdURL(for: id, in: dir)
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

    private func saveEntry(_ item: Item, in dir: URL) throws -> ItemRef {
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(item.id)
        }

        let currentURL = try mdURL(for: item.id, in: dir)
        let newFilename = Self.sanitizedTitle(item.title) + ".md"
        var targetURL = dir.appendingPathComponent(newFilename)

        // Rename if the title changed (filename is a projection of the title).
        if currentURL.lastPathComponent != newFilename {
            // Component-boundary guard: both URLs must be under this entry's dir.
            precondition(currentURL.deletingLastPathComponent().standardizedFileURL ==
                         dir.standardizedFileURL,
                         "NoteStore: source URL escapes entry dir")

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

    private func deleteEntry(_ id: UUID, in dir: URL) throws {
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw StoreError.notFound(id)
        }
        var resultURL: NSURL?
        try FileManager.default.trashItem(at: dir, resultingItemURL: &resultURL)
    }

    private func mdURL(for id: UUID, in dir: URL) throws -> URL {
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

    /// W7-S5 — write pre-named inline-image bytes into `id`'s `assets/<name>`, **without**
    /// re-disambiguating. The @MainActor `ItemAssetStore` is the single arbiter of asset names: it
    /// reserves a unique `name` synchronously and hands the editor the matching `assets/<name>` markdown
    /// reference, then calls this to persist the bytes at exactly that name. Contrast `importAsset`,
    /// which disambiguates itself and is used where the caller does *not* pre-commit a name. Guarantees:
    ///  - **Never overwrite** (no data loss): if `name` already exists, throws — a dangling reference
    ///    renders as a missing-asset placeholder, never a silent byte replacement.
    ///  - **Component boundary:** `name` must be a single path component, so a crafted name can't escape
    ///    the item's `assets/` dir.
    func writeReservedAsset(_ data: Data, name: String, into id: UUID) throws {
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else {
            throw StoreError.assetWriteFailed("unsafe asset name: \(name)")
        }
        let dir = assetsDir(id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let target = dir.appendingPathComponent(name)
        // Defense in depth: the resolved parent must be exactly the assets dir (matches `saveEntry`).
        precondition(target.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL,
                     "NoteStore.writeReservedAsset: name escapes assets dir")
        guard !fm.fileExists(atPath: target.path) else {
            throw StoreError.assetWriteFailed("asset already exists: \(name)")
        }
        do {
            try data.write(to: target, options: [.atomic])
        } catch {
            throw StoreError.assetWriteFailed(error.localizedDescription)
        }
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
