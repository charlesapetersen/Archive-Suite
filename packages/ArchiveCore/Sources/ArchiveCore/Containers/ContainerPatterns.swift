import Foundation

// MARK: - The name patterns, Route B (W47.ct-infer; `SPEC/containers.md` §The level map)
//
// What a directory or file name says about its container. These are the patterns `ct_read.py` (`name_class`,
// `tree_fields`) scored on the Route B tree set (`ArchiveProcessor/segbench-results/ct-read.md`), so a change here
// should be scored there too. Every value they give is a `path` value: worked out each time, never stored.

public enum ContainerPatterns {
    /// A workflow folder ("05 Final Tagging", "03 Unconverted (…)"): two digits and a space. It names no field and does
    /// not count as a level.
    public static func isWorkflowName(_ name: String) -> Bool {
        match(workflow, name) != nil
    }

    /// The role a directory's name suggests on its own, nil when it suggests none. `ignore` is a workflow folder.
    public static func role(ofName name: String) -> ContainerLevelRole? {
        benchClass(ofName: name).flatMap(role(ofBenchClass:))
    }

    /// `ct_read.py` `name_class`: "ignore", "container+folder", "container", "folder", "series", "accession",
    /// "collection", "repository" or nil. A box name with a title after it is not a box name here, as there.
    static func benchClass(ofName name: String) -> String? {
        if isWorkflowName(name) { return "ignore" }
        let s = cleaned(name)
        if boxAndFolder(s) != nil { return "container+folder" }
        if match(container, s).map({ $0[3].isEmpty }) == true || match(containerB, s) != nil { return "container" }
        if match(folder, s) != nil { return "folder" }
        if match(series, s) != nil { return "series" }
        if match(accession, s) != nil { return "accession" }
        if collectionParts(s) != nil || match(collectionWord, s) != nil { return "collection" }
        if match(repositoryWord, s) != nil { return "repository" }
        return nil
    }

    static func role(ofBenchClass c: String) -> ContainerLevelRole? {
        switch c {
        case "container", "container+folder": return .box
        default: return ContainerLevelRole(rawValue: c)
        }
    }

    /// The values a directory named `name` gives in `role`, each with source `path`.
    public static func fields(ofName name: String, role: ContainerLevelRole) -> ContainerFieldSet {
        let s = cleaned(name)
        guard !s.isEmpty else { return ContainerFieldSet() }
        var out: [ContainerField: String] = [:]
        switch role {
        case .ignore:
            break
        case .repository:
            out[.repository] = s
        case .collection:
            if let (title, number) = collectionParts(s) {
                out[.collectionNumber] = number
                if let title { out[.collectionTitle] = title }
            } else {
                out[.collectionTitle] = s
            }
        case .series:
            if let m = match(seriesSplit, s) {
                out[.series] = (m[1].isEmpty ? "Series " : "Subseries ") + m[2]
                if !m[3].isEmpty { out[.seriesTitle] = m[3] }
            } else {
                out[.series] = s
            }
        case .accession:
            if let m = match(accession, s) {
                out[.accession] = m[1].isEmpty ? m[2] : m[1]
            } else {
                out[.accession] = s
            }
        case .box, .folder:
            // A box or folder name may carry both numbers ("B17F8", "Box 10 - Folder 3"), so both roles read both.
            if let (box, folder, title) = boxAndFolder(s) {
                out[.container] = "Box " + number(box)
                out[.folder] = number(folder)
                if let title { out[.folderTitle] = title }
            } else if let m = match(container, s) {
                out[.container] = containerName(type: m[1], number: m[2])
                if !m[3].isEmpty { out[.boxTitle] = m[3] }
            } else if let m = match(containerB, s) {
                out[.container] = "Box " + number(m[1])
            } else if let m = match(folder, s) {
                out[.folder] = number(m[1])
                if !m[2].isEmpty { out[.folderTitle] = m[2] }
            } else {
                // A name with no number is the container's title.
                out[role == .box ? .boxTitle : .folderTitle] = s
            }
        }
        return ContainerFieldSet(out.mapValues { ContainerValue($0, source: .path) })
    }

    /// Box and folder numbers written into a file name ("Fromm, Box 2, Folder 4 - 0004.pdf"), source `path`.
    public static func fields(ofFileName fileName: String) -> ContainerFieldSet {
        let stem = cleaned((fileName as NSString).deletingPathExtension)
        guard let m = match(fileNumbers, stem) else { return ContainerFieldSet() }
        return ContainerFieldSet([.container: ContainerValue("Box " + number(m[1]), source: .path),
                                  .folder: ContainerValue(number(m[2]), source: .path)])
    }

    /// A "No Folder" sheet, recognised by its text: it starts a folder run with no fields (owner, 2026-11-13).
    public static func isNoFolderSheet(_ text: String) -> Bool {
        match(noFolder, text) != nil
    }

    // MARK: Parts

    /// Underscores read as spaces, spacing collapsed and trimmed.
    static func cleaned(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A number without its leading zeros ("08" is "8"), a letter suffix in capitals ("12a" is "12A").
    static func number(_ n: String) -> String {
        var digits = Substring(n)
        while digits.count > 1, digits.first == "0", digits.dropFirst().first?.isNumber == true { digits = digits.dropFirst() }
        return digits.last?.isLetter == true ? digits.uppercased() : String(digits)
    }

    /// "Box 17", "Carton 9": the type capitalised and its number (`ct_truth.py` `canon`).
    static func containerName(type: String, number n: String) -> String {
        let t = type.lowercased()
        let kind = ["bx": "box", "vol": "volume"][t] ?? t
        return kind.prefix(1).uppercased() + kind.dropFirst() + " " + number(n)
    }

    private static func boxAndFolder(_ s: String) -> (String, String, String?)? {
        if let m = match(bf, s) { return (m[1], m[2], nil) }
        if let m = match(boxFolder, s) { return (m[1], m[2], m[3].isEmpty ? nil : m[3]) }
        return nil
    }

    /// A collection number alone ("SC0122"), after the title ("Kristol, Mss 1036") or before it ("SC0122 News
    /// Service"): the number and the title, if any.
    private static func collectionParts(_ s: String) -> (String?, String)? {
        if match(collectionNumber, s) != nil { return (nil, s) }
        if let m = match(collectionNumberTail, s) { return (m[1], m[2]) }
        if let m = match(collectionNumberHead, s) { return m[1].isEmpty ? (m[4], m[3]) : (m[2], m[1]) }
        return nil
    }

    // MARK: Patterns (ct_read.py `N_*`)

    private static let collNo = #"(?:mss?|sc|rg|ru|r-mc|cbi|mc|m)\s?\d{2,}(?:[.\-]\d+)?|hug\s*\(fp\)\s*\d+(?:\.\d+)?"#
    private static let collNoTight = #"(?:mss?|sc|rg|ru|r-mc|cbi|mc|m)\d{2,}(?:[.\-]\d+)?"#
    /// A title after a number: set off by a spaced dash, a comma or a colon. "Box 1-3" and "ff. 1-20" are ranges.
    private static let titleTail = #"(?:(?:\s+[-–]|\s*[,:])\s*(.+))?$"#
    private static let workflow = regex(#"^\d\d "#, caseless: false)
    private static let bf = regex(#"^b\s?(\d+[a-z]?)\s?f\s?(\d+[a-z]?)$"#)
    private static let boxFolder = regex(
        #"^(?:box|bx)\.?\s*(\d+[a-z]?)\s*[-,;]?\s*(?:folder|fd|fldr?|f)\.?\s*(\d+[a-z]?)(?:\s*[-–,]\s*(.+))?$"#)
    private static let container = regex(
        #"^(box|bx|carton|folio|volume|vol|reel|drawer|oversize)\.?\s*(?:no\.?|#)?\s*(\d+[a-z]?(?:[-–]\d+[a-z]?)?)"# + titleTail)
    private static let containerB = regex(#"^b(\d+[a-z]?)$"#)
    private static let folder = regex(#"^(?:folder|fd|fldr?|f|ff)\.?\s*(?:no\.?|#)?\s*(\d+[a-z]?(?:[-–]\d+[a-z]?)?)"# + titleTail)
    private static let series = regex(#"^(?:series|entry|subseries)\s+\S+.*$"#)
    private static let seriesSplit = regex(#"^(sub)?series\s+((?-i:[IVXLC]+)|\d+[a-z]?)\b(?![\-–]\d)\.?\s*[,:.\-–]?\s*(.*)$"#)
    private static let accession = regex(#"^(?:accession|accn)\.?\s*(?:no\.?|#)?\s*([0-9][\w\-.]*)$|^(\d{4})\s+accession$"#)
    private static let collectionNumber = regex("^(?:\(collNo))$")
    private static let collectionNumberTail = regex(#"^(.*\S)\s*,\s*("# + collNo + ")$")
    private static let collectionNumberHead = regex("^(" + collNoTight + #")\s*[-,:]?\s+(\S.*)$|^("# + collNo
                                                    + #")\s*[-–,:]\s*(\S.*)$"#)
    private static let collectionWord = regex(#"\b(papers|records|collection|files|diaries|manuscripts)\b"#)
    private static let repositoryWord = regex(
        #"\b(archives?|library|libraries|institution|institute|society|museum|university|college|center|centre|foundation)\b"#)
    private static let fileNumbers = regex(#"\b(?:box|bx)\.?\s*(\d+[a-z]?)\s*,?\s*(?:folder|fd|f)\.?\s*(\d+[a-z]?)\b"#)
    private static let noFolder = regex(#"\bno\s+folders?\b"#)

    private static func regex(_ p: String, caseless: Bool = true) -> NSRegularExpression {
        // The patterns are literals: a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : [])
    }

    /// The first match in `s` (the whole of it, for an anchored pattern), as its groups (index 0 the whole; an unmatched group is ""), or nil.
    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }
}
