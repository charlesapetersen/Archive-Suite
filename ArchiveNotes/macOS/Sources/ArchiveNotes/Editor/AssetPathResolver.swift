import Foundation

/// The outcome of resolving one Markdown inline-image reference against an item's asset directory.
///
/// **W23.m3 — the READ seam.** A note body is a plain `.md` file the owner (or a sync client) can
/// hand-edit, so `![alt](path)` is *untrusted input*. `../OTHER_UUID/assets/private.png` used to
/// resolve — the reference was appended to the item directory and merely checked for existence — so a
/// note rendered another note's image, and copy/extract code (`NotePassageSource` → `ExtractBuilder`,
/// which re-keys assets by *bare filename*) could then snapshot those foreign bytes into a third item.
/// That corrupts provenance, not just the visual boundary.
///
/// `resolved` therefore carries a **canonical** URL — symlinks resolved, `.`/`..` standardized — proven
/// to sit inside `<item>/assets/`. Being canonical is also what makes it usable as a per-asset identity.
enum AssetResolution: Equatable {

    /// A canonical file URL inside `<item>/assets/`. The only case whose bytes may be read.
    case resolved(URL)

    /// In bounds, but nothing readable is there — a dangling reference, or a paste whose byte write is
    /// still in flight (`ItemAssetStore.addAsset` hands out the name before the actor writes it).
    case missing

    /// The reference points outside `<item>/assets/`. Refused: never opened, never read.
    case outOfBounds
}

/// Containment for the inline-image **read** seam: resolve a Markdown image reference inside exactly
/// one item's `assets/` directory, or refuse it.
///
/// Two independent gates, because either one alone is bypassable:
///  1. a **syntactic** gate on the reference itself — `assets/`-rooted, no `..`, not absolute. This is
///     what a `../OTHER_UUID/assets/x.png` traversal hits, before any file system access at all.
///  2. a **canonical containment** gate on the resolved URL. This is what a *symlink* inside `assets/`
///     hits: `FileManager.fileExists` follows symlinks and `standardizedFileURL` does **not** resolve
///     them, so `assets/link.png` pointing at another item passes every string check. Only
///     `resolvingSymlinksInPath()` exposes the target — verified on this platform, where it also
///     normalizes the `/private/var` ↔ `/var` alias, and does so identically for both sides of the
///     comparison (so the base and the candidate can never end up as two spellings of one directory).
enum AssetPathResolver {

    /// The one directory an item's inline images may live in (mirrors `NoteStore.assetsDir`).
    static let assetsFolder = "assets"

    /// Resolve `reference` — a Markdown image path such as `assets/photo.png` — against `itemDir`
    /// (`<store root>/items/<uuid>`). Never throws, and never reads file *contents*; it only asks the
    /// file system where the path lands.
    static func resolve(_ reference: String,
                        inItemDirectory itemDir: URL,
                        fileManager: FileManager = .default) -> AssetResolution {
        // Gate 1 — syntactic. The contract is a store-relative `assets/…` reference; anything else
        // (absolute path, `~`, a `..` component, a non-`assets` root, a remote URL) is out of bounds by
        // construction, so refuse it without touching the disk.
        guard !reference.hasPrefix("/"), !reference.hasPrefix("~") else { return .outOfBounds }
        let components = reference.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2,
              components[0] == assetsFolder,
              !components.contains("..")
        else { return .outOfBounds }

        var candidate = itemDir
        for component in components { candidate.appendPathComponent(component) }
        guard fileManager.fileExists(atPath: candidate.path) else { return .missing }

        // Gate 2 — canonical containment. Catches a symlink *inside* `assets/` whose target is
        // elsewhere: gate 1 sees a perfectly ordinary `assets/<name>` reference.
        let canonical = canonicalize(candidate)
        let base = canonicalize(itemDir.appendingPathComponent(assetsFolder, isDirectory: true))
        guard isDescendant(canonical, of: base) else { return .outOfBounds }
        return .resolved(canonical)
    }

    /// Canonical form, applied to BOTH sides of the containment comparison.
    private static func canonicalize(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Component-wise ancestry. A string `hasPrefix` would accept a *sibling* whose name merely starts
    /// with the base's — `…/assets-elsewhere/x.png` against a base of `…/assets`.
    private static func isDescendant(_ url: URL, of base: URL) -> Bool {
        let baseComponents = base.pathComponents
        let urlComponents = url.pathComponents
        guard urlComponents.count > baseComponents.count else { return false }
        return Array(urlComponents.prefix(baseComponents.count)) == baseComponents
    }
}
