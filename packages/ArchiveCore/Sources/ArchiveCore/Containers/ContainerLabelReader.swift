import Foundation

/// A box or folder label photo read into container fields (Route A; `SPEC/containers.md` §Route A, W47.ct-processor-capture).
///
/// `parse` is `ct_read.py` `vision_read`, the "Apple Vision + parser" route `segbench-results/ct-read.md` scored: the
/// photo's text lines and its item type (the Box or Folder button) in, every field it finds out. A change here is
/// scored there too. `proposals` takes from it, and from a model's reading when there is one, only the fields each
/// reader was chosen for (owner, 2026-11-13, `W47.ct-design-ok`). Every value is a proposal (source `label`) the user
/// confirms on the capture card.
public enum ContainerLabelReader {
    /// The `reader` of a value from `parse`.
    public static let visionReader = "vision+parser"

    /// The fields a model's reading of the photo may give, as `ct_truth.py`'s prompt names them.
    public static let modelFields: [ContainerField] = [.repository, .collectionTitle, .collectionNumber, .date,
                                                       .accession, .container]

    // MARK: The parser (`ct_read.py` `vision_read`)

    /// Every field the patterns find in `lines` (Vision's lines, top to bottom), the photo being a label of `type`.
    /// Titles: a repository line, a collection line, and on a folder its longest unused line.
    public static func parse(lines: [String], type: ItemType) -> [ContainerField: String] {
        let texts = lines.compactMap(clean)
        var out: [ContainerField: String] = [:]
        var used = Set<Int>()
        func take(_ field: ContainerField, _ value: String?, _ i: Int) {
            guard out[field] == nil, let value, !value.isEmpty else { return }
            out[field] = value
            used.insert(i)
        }

        for (i, t) in texts.enumerated() {
            if let m = search(container, t) { take(.container, canonContainer(m[0]), i) }
            if let m = search(folder, t), search(filesWord, t) == nil { take(.folder, m[1], i) }
            if let m = search(accession, t) { take(.accession, m[1], i) }
            if let m = search(series, t) {
                take(.series, "Series " + m[1], i)
                let rest = m[2].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { take(.seriesTitle, rest, i) }
            }
            if let m = search(collectionNumber, t), search(container, m[1]) == nil { take(.collectionNumber, m[1], i) }
            if let m = search(date, t) { take(.date, m[0], i) }
        }
        // A folder's "5-9", and a lone number standing for the container or the folder.
        for (i, t) in texts.enumerated() {
            if let m = search(pair, t), type == .folder, out[.container] == nil, out[.folder] == nil {
                take(.container, "Box " + m[1], i)
                take(.folder, m[2], i)
            }
        }
        for (i, t) in texts.enumerated() {
            if let m = search(bare, t), !used.contains(i) {
                if type == .box { take(.container, "Box " + m[1], i) } else { take(.folder, m[1], i) }
            }
        }
        for (i, t) in texts.enumerated() where !used.contains(i) {
            if search(repositoryWord, t) != nil, search(collectionWord, t) == nil {
                take(.repository, t, i)
            } else if search(collectionWord, t) != nil {
                take(.collectionTitle, t, i)
            }
        }
        if type == .folder {
            let rest = texts.enumerated().filter { !used.contains($0.offset) && $0.element.filter(\.isLetter).count >= 3 }
            // Python's max over (length, index, text): the longest, the later on a tie.
            if let best = rest.max(by: { ($0.element.count, $0.offset) < ($1.element.count, $1.offset) }) {
                take(.folderTitle, best.element, best.offset)
            }
        }
        return out
    }

    // MARK: Proposals per reader (owner, 2026-11-13)

    /// The values the capture card proposes for a label of `type`, all source `label`:
    /// - container and folder number, series and series title from the parser; the container from the model where the
    ///   parser reads none (Vision misses about a quarter of the box numbers there, `ct-read.md`);
    /// - repository, collection title, collection number, date and accession from the model when there is one
    ///   (`model`, its values by field, read by `modelReader`), else from the parser;
    /// - collection subtitle, box title, folder title and other marks from nobody: no route reads them (`ct-read.md`),
    ///   so the user writes them.
    /// A folder label keeps only what a folder run stores (`ContainerInference.applyMarkers` drops the rest).
    /// `parserReader` names where the lines came from: `visionReader` for Apple Vision's lines, the route scored;
    /// another name for other text (an LLM transcript), which the bench has not scored.
    public static func proposals(lines: [String], type: ItemType, model: [ContainerField: String]? = nil,
                                 modelReader: String? = nil, parserReader: String = visionReader,
                                 at date: Date? = nil) -> ContainerFieldSet {
        let parsed = parse(lines: lines, type: type)
        var set = ContainerFieldSet()
        func put(_ field: ContainerField, _ value: String?, _ reader: String?) {
            guard var value = value.flatMap(clean), set[field] == nil else { return }
            if field == .folder { value = ContainerPatterns.number(value) }   // "08" is folder 8 (§Name patterns)
            set[field] = ContainerValue(value, source: .label, reader: reader, at: date)
        }
        let modelValues = (model ?? [:]).filter { modelFields.contains($0.key) }
        for field in [ContainerField.container, .folder, .series, .seriesTitle] {
            put(field, parsed[field], parserReader)
        }
        if let container = modelValues[.container].flatMap(clean) {
            put(.container, canonContainer(container), modelReader)
        }
        for field in [ContainerField.repository, .collectionTitle, .collectionNumber, .date, .accession] {
            if let m = modelValues[field].flatMap(clean) { put(field, m, modelReader) } else { put(field, parsed[field], parserReader) }
        }
        if type == .folder {
            set.values = set.values.filter { [.folder, .folderTitle, .date, .other].contains($0.key) }
        }
        return set
    }

    /// The model's reply (a JSON object, perhaps inside other text, with `ct_truth.py`'s snake-case keys), as fields.
    public static func modelFields(fromReply raw: String) -> [ContainerField: String] {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let data = String(raw[open...close]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [ContainerField: String] = [:]
        for field in modelFields {
            let value: String?
            switch object[field.benchName] {
            case let s as String: value = s
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
                value = n.doubleValue.rounded() == n.doubleValue ? String(n.intValue) : n.stringValue
            default: value = nil
            }
            if let v = value.flatMap(clean) { out[field] = v }
        }
        return out
    }

    /// The prompt for a model's reading of a label photo: `ct_truth.py` `PROMPT` cut to the fields the model is chosen
    /// for. The image goes with it.
    public static let modelPrompt = """
        This photo was taken in an archive reading room. It may show a box label, a folder label or tab, a divider \
        sheet, or a page of a document. Read what is written on the label, if there is one, into these fields. Use \
        null for anything not written there; do not guess from general knowledge. Reply with JSON only:
        {"repository": the archive or library, e.g. "Hoover Institution Archives",
         "collection_title": e.g. "Irving Kristol Papers, 1946-2001",
         "collection_number": a call or collection number, e.g. "Mss 1036", "SC0122", "RG 165",
         "accession": an accession number, e.g. "91006-10.V", only if the label says accession,
         "container": the container type and number exactly as written, e.g. "Box 17", "Carton 9",
         "date": the date or time period written on the label, e.g. "1946-2001"}
        """

    // MARK: Parts

    /// `ct_truth.py` `clean`: spacing collapsed and trimmed; nothing for an empty or placeholder value.
    static func clean(_ v: String) -> String? {
        let s = v.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ["", "null", "none", "n/a", "unknown", "not visible", "-"].contains(s.lowercased()) ? nil : s
    }

    /// `ct_truth.py` `canon`: the container as its type and own number ("Box 34" from "BOX #34", "Box 34 of 201" or a
    /// bare "34"); anything else as written.
    static func canonContainer(_ v: String) -> String {
        if let m = search(container, v) {
            let type = m[1].lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let kind = type == "vol" ? "volume" : type
            var n = Substring(m[2])
            while n.count > 1, n.first == "0", n.dropFirst().first?.isNumber == true { n = n.dropFirst() }
            return kind.prefix(1).uppercased() + kind.dropFirst() + " " + (n.last?.isLetter == true ? n.uppercased() : String(n))
        }
        if let m = search(bareContainer, v) { return "Box " + m[1] }
        return v
    }

    // MARK: Patterns (`ct_read.py` `P_*`, `ct_truth.py` `CONTAINER`)

    private static let year = #"(?:1[6-9]\d\d|20[0-4]\d)"#
    private static let container = regex(#"\b(box|carton|folio|volume|vol|reel|drawer|oversize|flat\s*file|bin|case|item)\b\.?"#
                                         + #"\s*(?:no\.?|number|#)?\s*([0-9]+[a-z]?)"#)
    private static let bareContainer = regex(#"^\s*(?:no\.?|#)?\s*(\d+[a-z]?)\s*$"#)
    // `P_DATE` and `P_PAIR` are case-sensitive in `ct_read.py` ("1950S" is no date there).
    private static let date = regex(#"\b\#(year)\s*[-–—]\s*(?:\#(year)|\d\d)\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b|\b\#(year)s?\b"#,
                                    caseless: false)
    private static let folder = regex(#"\b(?:folder|fol|fldr?|fd|ff?)\b\.?\s*(?:no\.?|#|number)?\s*(\d+[a-z]?)\b"#)
    private static let filesWord = regex(#"\bfiles?\b"#)
    private static let pair = regex(#"^\s*(\d{1,3})\s*[-.:/]\s*(\d{1,3})\s*$"#, caseless: false)
    private static let collectionNumber = regex(#"\b((?:mss?|sc|rg|ru|r-mc|cbi|mc|hug(?:\s*\(fp\))?|m|coll(?:ection)?\.?\s*(?:no\.?)?)"#
                                                + #"\s?\.?\s?\d{2,}(?:[.\-]\d+)?)\b"#)
    private static let accession = regex(#"\b(?:accession|accn|acc)\b\.?\s*(?:no\.?|#|number)?\s*:?\s*([0-9][\w\-.]*)"#)
    private static let series = regex(#"\bseries\s+([IVXLC]+|\d+[a-z]?)\b\.?\s*[,:.\-–]?\s*(.*)$"#)
    private static let repositoryWord = regex(#"\b(archives?|library|libraries|institution|institute|society|museum|university|college|"#
                                              + #"center|centre|foundation)\b"#)
    private static let collectionWord = regex(#"\b(papers|records|collection|files|diaries|manuscripts)\b"#)
    private static let bare = regex(#"^\s*(?:no\.?|#)?\s*(\d{1,3}[a-z]?)\s*$"#)

    private static func regex(_ p: String, caseless: Bool = true) -> NSRegularExpression {
        // The patterns are literals: a failure here is a programming error caught by the tests.
        try! NSRegularExpression(pattern: p, options: caseless ? [.caseInsensitive] : [])
    }

    /// The first match in `s` as its groups (index 0 the whole; an unmatched group is ""), or nil.
    private static func search(_ re: NSRegularExpression, _ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

extension ContainerInference {
    /// What `recordMarkers` did.
    public enum RecordOutcome: Equatable, Sendable {
        /// The container file was written (or created) with the markers applied.
        case wrote([ContainerWarning])
        /// The markers changed nothing the file holds, so nothing was written.
        case unchanged([ContainerWarning])
        /// The document on disk is newer or unreadable: left alone (`SPEC/containers.md` §The container file).
        case leftAlone(String)
    }

    /// Applies one directory's markers (`applyMarkers`) to its container file and writes it, for the Processor at
    /// finalize (W47.ct-processor-capture): the user has confirmed each marker's fields on the capture card, so this
    /// is the "accept" the SPEC asks of the caller. New files only, inside `.archivesuite` (`ContainerFileStore.write`);
    /// a document this build cannot read or that is newer is never overwritten or set aside. A document that changes
    /// between the read and the write is read again once.
    public static func recordMarkers(_ markers: [ContainerMarker], in directory: URL, now: Date = Date()) throws
        -> RecordOutcome {
        for attempt in 0..<2 {
            let file: ContainerFile
            let stamp: ContainerFileStamp?
            switch ContainerFileStore.load(directory: directory) {
            case .missing: (file, stamp) = (ContainerFile(), nil)
            case .loaded(let d, let s):
                if s.droppedOnReading { return .leftAlone("holds values this build does not read") }
                (file, stamp) = (d, s)
            case .newer: return .leftAlone("written by a newer version")
            case .unreadable(let why): return .leftAlone(why)
            }
            let (applied, warnings) = applyMarkers(markers, to: file)
            if applied.runs == file.runs && applied.directory == file.directory { return .unchanged(warnings) }
            var out = applied
            out.updatedAt = now
            do {
                try ContainerFileStore.write(out, directory: directory, expecting: stamp)
                return .wrote(warnings)
            } catch ContainerWriteError.changedSinceRead where attempt == 0 {
                continue
            }
        }
        throw ContainerWriteError.changedSinceRead
    }
}
