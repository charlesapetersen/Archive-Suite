import Foundation

/// Pure, total parser for `zotero://select/…` links (00-overview §D.2).
/// Returns `nil` for unrecognized links — never throws or crashes.
enum ZoteroSelectLink {

    /// Parse a `zotero://select/…` URL string into a `ZoteroRef`.
    /// Re-emits a canonical `selectLink` regardless of which variant was pasted.
    static func parse(_ string: String) -> ZoteroRef? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "zotero",
              url.host?.lowercased() == "select" else { return nil }

        let components = url.pathComponents
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { $0 != "/" }
        guard !components.isEmpty else { return nil }

        let library: ZoteroLibrary
        let key: String

        if components.count >= 3,
           components[0].lowercased() == "library",
           components[1].lowercased() == "items" {
            // Form 1: library/items/<KEY>
            key = components[2]
            library = .user
        } else if components.count >= 4,
                  components[0].lowercased() == "groups",
                  let gid = Int(components[1]),
                  components[2].lowercased() == "items" {
            // Form 2: groups/<GID>/items/<KEY>
            key = components[3]
            library = .group(gid)
        } else if components.count >= 2,
                  components[0].lowercased() == "items" {
            let raw = components[1]
            if let underscoreIdx = raw.firstIndex(of: "_") {
                // Form 3: items/<libID>_<KEY>
                let libPart = String(raw[raw.startIndex..<underscoreIdx])
                key = String(raw[raw.index(after: underscoreIdx)...])
                let libID = Int(libPart)
                library = (libID == nil || libID == 0 || libID == 1) ? .user : .group(libID!)
            } else {
                // Form 4: items/<KEY>
                key = raw
                library = .user
            }
        } else {
            return nil
        }

        guard isValidKey(key) else { return nil }

        let canonical: String
        switch library {
        case .user:
            canonical = "zotero://select/library/items/\(key)"
        case .group(let gid):
            canonical = "zotero://select/groups/\(gid)/items/\(key)"
        }

        return ZoteroRef(selectLink: canonical, itemKey: key, library: library)
    }

    /// Zotero keys: exactly 8 uppercase alphanumeric characters.
    private static func isValidKey(_ key: String) -> Bool {
        key.count == 8 && key.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
