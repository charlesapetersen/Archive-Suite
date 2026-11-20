import Foundation
import UniformTypeIdentifiers

/// **W49.notes-auto-copy-images** — an image a note names outside its `assets/` folder is copied in,
/// rather than left showing "Blocked" (owner, 2026-11-19, call 22: "Shouldn't we just prevent this from
/// happening in the first place by automatically copying in such images?").
///
/// The read seam stays exactly as strict as W23.m3 made it: `AssetPathResolver` still reads only
/// `<item>/assets/`. What changes is that such a reference no longer stays one. This type decides which
/// references can be copied in without asking, and rewrites them once they have been; the copy itself goes
/// through `ItemAssetStore`, the single asset name arbiter, so a copied file can never take a name a paste
/// still has in flight.
///
/// Three outcomes for a local reference that is not already `assets/…`:
///  - a readable image **inside the note's own folder** (`photo.png` at the item root, a mis-cased
///    `Assets/x.png`, `sub/x.png`) is copied in automatically;
///  - a path **outside the note's folder** (absolute, `~`, a `..` that leaves it, a symlink pointing out)
///    is never opened unasked: the sandbox may not grant it, and it may be another note's file, which is
///    the provenance hole W23.m3 closed. The user picks it once; the open panel grants the read;
///  - a path inside the folder with **nothing readable** there stays Blocked.
/// A remote reference (`https:` and other schemes) is not a file and is left alone.
enum StrayImageAdoption {

    enum Kind: Equatable {
        /// A regular image file inside the note's folder, outside `assets/`: copied in automatically.
        case inNoteFolder(URL)
        /// A local path that leaves the note's folder: offered to the user to pick once.
        case outsideNoteFolder
        /// Inside the note's folder, but no readable image is there: stays Blocked.
        case notFound
    }

    /// One `![label](destination)` occurrence: `label` still escaped as written, `path` decoded.
    struct Reference: Equatable {
        let range: NSRange
        let label: String
        let path: String
    }

    /// Every image reference in `body`, in the grammar the renderer reads (`InlineImageMarkdown.pattern`,
    /// matched over the whole body exactly as `MarkdownBridge` does, so what is rewritten is what renders).
    static func references(in body: String) -> [Reference] {
        let ns = body as NSString
        return InlineImageMarkdown.pattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { match in
                Reference(range: match.range,
                          label: ns.substring(with: match.range(at: 1)),
                          path: InlineImageMarkdown.decodeDestination(ns.substring(with: match.range(at: 2))))
            }
    }

    /// Whether `body` names any image that is not a plain `assets/…` reference. Synchronous and
    /// disk-free, so a note with no such image never pays for an adoption pass.
    static func hasCandidates(_ body: String) -> Bool {
        guard body.contains("![") else { return false }
        return references(in: body).contains { isCandidate($0.path) }
    }

    /// nil = not this type's business: already `assets/`-rooted (the read seam decides those), or remote.
    static func classify(_ reference: String, inItemDirectory itemDir: URL,
                         fileManager: FileManager = .default) -> Kind? {
        guard isCandidate(reference) else { return nil }
        if reference.hasPrefix("/") || reference.hasPrefix("~") || hasScheme(reference) {
            return .outsideNoteFolder
        }
        var candidate = itemDir
        for component in reference.split(separator: "/", omittingEmptySubsequences: true) {
            candidate.appendPathComponent(String(component))
        }
        // The same canonical comparison as the read seam: symlinks resolved on both sides, so a link
        // inside the folder that points elsewhere counts as elsewhere.
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        let base = itemDir.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(canonical, of: base) else { return .outsideNoteFolder }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: canonical.path),
              isImage(canonical)
        else { return .notFound }
        return .inNoteFolder(canonical)
    }

    /// `body` with every reference whose decoded path is a key of `newPaths` pointed at its value. The
    /// label is kept byte for byte; the destination is spelled by `InlineImageMarkdown.destination`.
    static func rewriting(_ body: String, _ newPaths: [String: String]) -> String {
        guard !newPaths.isEmpty else { return body }
        let result = NSMutableString(string: body)
        for ref in references(in: body).reversed() {
            guard let path = newPaths[ref.path] else { continue }
            result.replaceCharacters(in: ref.range,
                                     with: "![\(ref.label)](\(InlineImageMarkdown.destination(path)))")
        }
        return result as String
    }

    /// The name a copied file takes in `assets/`: its own last component, or `image` if it has none.
    static func assetName(for source: URL) -> String {
        let name = source.lastPathComponent
        return name.isEmpty || name == "/" || name == "." || name == ".." ? "image" : name
    }

    // MARK: - Private

    /// A plain `assets/…` reference with no `..` is the read seam's; a remote one is nobody's.
    private static func isCandidate(_ reference: String) -> Bool {
        guard !reference.isEmpty else { return false }
        if hasScheme(reference) { return reference.lowercased().hasPrefix("file:") }
        let components = reference.split(separator: "/", omittingEmptySubsequences: true)
        let plainAsset = !reference.hasPrefix("/") && components.count >= 2
            && components[0] == Substring(AssetPathResolver.assetsFolder) && !components.contains("..")
        return !plainAsset
    }

    private static func hasScheme(_ reference: String) -> Bool {
        reference.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    /// Component-wise ancestry, as in `AssetPathResolver` (a string prefix would accept a sibling).
    private static func isDescendant(_ url: URL, of base: URL) -> Bool {
        let baseComponents = base.pathComponents
        let urlComponents = url.pathComponents
        guard urlComponents.count > baseComponents.count else { return false }
        return Array(urlComponents.prefix(baseComponents.count)) == baseComponents
    }
}

/// What one adoption pass did to a body.
struct StrayImageOutcome: Equatable, Sendable {
    /// The body with every copied reference rewritten (equal to the input when nothing was copied).
    var body: String
    /// The asset names the copied images took, in body order.
    var copied: [String]
    /// References outside the note's folder, for the user to pick once.
    var toPick: [String]
}
