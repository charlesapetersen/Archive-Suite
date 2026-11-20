import Foundation

/// Pure, total parser for `zotero://select/…` links (00-overview §D.2), and for the page-anchored
/// `zotero://open-pdf/…?page=N` links Zotero copies for a place in a PDF (W49.notes-zotero-page-links).
/// Returns `nil` for unrecognized links — never throws or crashes.
enum ZoteroSelectLink {

    /// Parse a `zotero://select/…` or `zotero://open-pdf/…` URL string into a `ZoteroRef`.
    /// Re-emits a canonical `selectLink` regardless of which variant was pasted. An `open-pdf` link (or
    /// Zotero 7's `open`, its successor) names an attachment, so the ref is `.attachment`, with its
    /// positive `page` when the link gives one.
    static func parse(_ string: String) -> ZoteroRef? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "zotero",
              let host = url.host?.lowercased() else { return nil }
        let opensPDF = host == "open-pdf" || host == "open"
        guard host == "select" || opensPDF else { return nil }

        let components = url.pathComponents
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { $0 != "/" }
        guard !components.isEmpty else { return nil }

        let library: ZoteroLibrary
        let key: String
        var legacyPage: Int?

        if opensPDF, components.count == 2, components[1].allSatisfy(\.isNumber),
           let underscoreIdx = components[0].firstIndex(of: "_") {
            // ZotFile's form, which Zotero still answers: open-pdf/<libID>_<KEY>/<page>
            let raw = components[0]
            let libID = Int(raw[raw.startIndex..<underscoreIdx])
            key = String(raw[raw.index(after: underscoreIdx)...])
            library = (libID == nil || libID == 0 || libID == 1) ? .user : .group(libID!)
            legacyPage = Int(components[1])
        } else if components.count >= 3,
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

        guard opensPDF else { return ZoteroRef(selectLink: canonical, itemKey: key, library: library) }
        let page = (legacyPage ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.lowercased() == "page" }?.value.flatMap { Int($0) })
            .flatMap { $0 > 0 ? $0 : nil }
        return ZoteroRef(selectLink: canonical, itemKey: key, library: library, kind: .attachment, page: page)
    }

    /// The link that opens the attachment `selectLink` names at `page` in Zotero's reader. `open-pdf` rather
    /// than Zotero 7's `open`, since Zotero 6 and 7 both answer it. `nil` when `selectLink` is not one this
    /// parser reads or `page` is not positive.
    static func openPDFLink(selectLink: String, page: Int) -> URL? {
        guard page > 0, let ref = parse(selectLink) else { return nil }
        switch ref.library {
        case .user:
            return URL(string: "zotero://open-pdf/library/items/\(ref.itemKey)?page=\(page)")
        case .group(let gid):
            return URL(string: "zotero://open-pdf/groups/\(gid)/items/\(ref.itemKey)?page=\(page)")
        }
    }

    /// Zotero keys: exactly 8 uppercase alphanumeric characters.
    private static func isValidKey(_ key: String) -> Bool {
        key.count == 8 && key.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
