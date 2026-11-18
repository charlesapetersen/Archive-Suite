import Foundation

// MARK: - The container's CSL-JSON variables (W47.ct-spec; `SPEC/containers.md` §Zotero)
//
// Only the container's part of an export; `W47.ct-zotero` adds the item's own fields and writes the file. No citation
// is formatted, and an empty field is left out.

public struct ContainerCSL: Equatable, Sendable {
    /// `archive`, `archive-place`, `archive_collection`, `call-number`, `archive_location`.
    public var variables: [String: String]
    /// Lines for CSL `note`, which Zotero imports into Extra: `accession: …`, `series: …`.
    public var noteLines: [String]

    public init(_ record: ResolvedContainer) {
        let v = { (f: ContainerField) in record.shown(f) }
        var vars: [String: String] = [:]
        vars["archive"] = v(.repository)
        vars["archive-place"] = v(.place)
        vars["call-number"] = v(.collectionNumber)
        vars["archive_collection"] = ContainerCSL.join([v(.collectionTitle), v(.collectionSubtitle)], ": ")

        var box = v(.container)
        if let title = v(.boxTitle) { box = box.map { "\($0) (\(title))" } ?? "(\(title))" }
        let folder = v(.folder).map { ContainerCSL.namesFolder($0) ? $0 : "Folder \($0)" }
        vars["archive_location"] = ContainerCSL.join([box, folder, v(.folderTitle)], ", ")
        variables = vars

        var lines: [String] = []
        if let accession = v(.accession) { lines.append("accession: \(accession)") }
        if let series = ContainerCSL.join([v(.series), v(.seriesTitle)], ", ") { lines.append("series: \(series)") }
        noteLines = lines
    }

    /// The folder value already says what it is ("Folder 8", "f. 5", "ff. 2-3").
    static func namesFolder(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("folder") || lower.hasPrefix("f.") || lower.hasPrefix("ff.")
    }

    static func join(_ parts: [String?], _ separator: String) -> String? {
        let kept = parts.compactMap { $0 }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }
}
