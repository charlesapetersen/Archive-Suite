import ArchiveCore
import Foundation
import Testing
@testable import ArchiveNotes

/// W40.e6 — parser robustness for the note file format. `NotesFrontMatterTests` (W8-S1) already fuzzes
/// random blobs and simple items; this suite takes a FULL note (Zotero refs, a sent-with date, a display
/// calendar, unknown keys, source-anchored blocks) and damages its saved text — truncation, flipped
/// characters, deleted and duplicated lines, nested fences and block headers. The bar: a crash or a silent
/// wrong value is a bug, a clean `CodecError` is a pass. "Silent wrong value" here means drift across saves:
/// whatever `decode` accepts, the app writes back with `encode`, and that text must itself decode to the
/// same note and re-encode byte for byte, so a damaged file settles after one save instead of changing on
/// every autosave.
@Suite("FrontMatterMutationFuzzTests — W40.e6 note-file damage and round trips")
struct FrontMatterMutationFuzzTests {

    /// Every field of a well-formed full note survives write-then-read exactly.
    @Test
    func fullNotesRoundTripExactly() throws {
        var rng = NoteFuzzRNG(seed: 0xE6_0A7E)
        for i in 0..<1_500 {
            let item = NoteFuzz.item(&rng, tricky: false)
            let text = FrontMatterCodec.encode(item)
            let back = try FrontMatterCodec.decode(text)
            NoteFuzz.expectSameNote(back, item, "iteration \(i)\n\(text)")
            #expect(FrontMatterCodec.encode(back) == text, "iteration \(i): re-encode changed the file")
        }
    }

    /// Values with header-breaking characters (`-->`, quotes beside backslashes, `: `, `#`, line breaks in a
    /// block's display) may be normalized by the writer, but only once: the saved text is a fixed point.
    @Test
    func trickyNotesSettleAfterOneSave() throws {
        var rng = NoteFuzzRNG(seed: 0xE6_7121)
        for i in 0..<1_500 {
            let item = NoteFuzz.item(&rng, tricky: true)
            let text = FrontMatterCodec.encode(item)
            let back = try FrontMatterCodec.decode(text)
            let text2 = FrontMatterCodec.encode(back)
            let text3 = FrontMatterCodec.encode(try FrontMatterCodec.decode(text2))
            #expect(text3 == text2,
                    "iteration \(i): the file keeps changing across saves\n\(text)")
            #expect(back.id == item.id, "iteration \(i)")
            #expect(back.title == item.title, "iteration \(i): title \(item.title.debugDescription) → \(back.title.debugDescription)")
            #expect(back.tags == item.tags, "iteration \(i): tags \(item.tags.debugDescription) → \(back.tags.debugDescription)")
            #expect(back.authors == item.authors, "iteration \(i): authors \(item.authors.debugDescription) → \(back.authors.debugDescription)")
            #expect(back.zotero.map(\.citation) == item.zotero.map(\.citation), "iteration \(i): citation")
            #expect(back.sentWith == item.sentWith && back.blocks.count == item.blocks.count, "iteration \(i)")
        }
    }

    /// Damaged saved text: decode either throws a typed error or yields a note whose own save is stable.
    @Test
    func damagedNoteFilesDecodeCleanlyOrSettle() {
        var rng = NoteFuzzRNG(seed: 0xE6_DA3A)
        var accepted = 0
        for i in 0..<4_000 {
            let original = FrontMatterCodec.encode(NoteFuzz.item(&rng, tricky: rng.chance(0.3)))
            let damaged = NoteFuzz.damage(original, &rng)
            let item: Item
            do {
                item = try FrontMatterCodec.decode(damaged)
            } catch {
                #expect(error is FrontMatterCodec.CodecError, "iteration \(i): untyped \(type(of: error))")
                continue
            }
            accepted += 1
            let saved = FrontMatterCodec.encode(item)
            guard let reread = try? FrontMatterCodec.decode(saved) else {
                Issue.record("iteration \(i): the app's own save of a decoded note does not decode\n\(damaged.debugDescription)")
                continue
            }
            #expect(FrontMatterCodec.encode(reread) == saved,
                    "iteration \(i): a damaged file keeps changing across saves\n\(damaged.debugDescription)")
            // A save may drop an unknown key a known field supersedes (a duplicated `display_calendar`), never
            // invent one, and never lose the marker key every generated note may carry.
            #expect(reread.id == item.id && reread.blocks.count == item.blocks.count
                    && reread.unknownFrontMatter.allSatisfy(item.unknownFrontMatter.contains)
                    && item.unknownFrontMatter.filter { $0.key == "x_extra" } == reread.unknownFrontMatter.filter { $0.key == "x_extra" },
                    "iteration \(i): the second read lost something\n\(damaged.debugDescription)")
        }
        // Not a pass condition: proof the damage leaves enough decodable files to exercise the save path.
        #expect(accepted > 500, "only \(accepted)/4000 damaged files decoded — the loop is not reaching encode")
    }

    /// The case `damagedNoteFilesDecodeCleanlyOrSettle` found (W40.e6), fixed in `BlockParser`: a block header
    /// cut off before its `-->` degrades to a freeform block (§6, `BlockHeaderTests`), and used to come back
    /// from every save under one more empty `<!-- block: freeform -->`, so the file grew by a block per save.
    @Test
    func unterminatedBlockHeaderIsWrittenBackAsItWas() throws {
        let id = UUID().uuidString.lowercased()
        let text = "---\nschema: 1\nid: \(id)\nkind: note\ntitle: T\nroundup: false\n"
            + "created: 2020-01-01T00:00:00Z\nmodified: 2020-01-01T00:00:00Z\n---\n"
            + "<!-- block: freeform -->\nFirst.\n<!-- block: reader-doc\n     link: archivereader://open?path=a.pdf"
        for body in [text, text.replacingOccurrences(of: "<!-- block: freeform -->\nFirst.\n", with: "")] {
            let first = try FrontMatterCodec.decode(body)
            #expect(first.blocks.last?.kind == .freeform && first.blocks.last?.source == nil)
            #expect(first.blocks.last?.markdown == "<!-- block: reader-doc\n     link: archivereader://open?path=a.pdf")
            let saved = FrontMatterCodec.encode(first)
            #expect(saved == body, "the save must write the file back as it was")
            #expect(try FrontMatterCodec.decode(saved).blocks.count == first.blocks.count)
        }
    }

    /// The same file through the editor: the bridge's save writes a header for every chip, so a degraded
    /// block must not get one — or every edit-and-save in the window adds a block, as the store's did.
    @Test @MainActor
    func unterminatedBlockHeaderSurvivesTheEditor() {
        for body in ["<!-- block: freeform -->\nFirst.\n<!-- block: reader-doc\n     link: x",
                     "Intro.\n<!-- block: reader-doc\n     link: x"] {
            let once = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: body))
            let twice = MarkdownBridge.serialize(MarkdownBridge.parse(markdown: once))
            #expect(once == twice, "the editor's save keeps changing \(body.debugDescription): \(once.debugDescription) → \(twice.debugDescription)")
            #expect(BlockParser.parse(once).blocks.count == BlockParser.parse(body).blocks.count,
                    "\(body.debugDescription) → \(once.debugDescription)")
            #expect(once.contains("<!-- block: reader-doc"), "the unclosed text was dropped: \(once.debugDescription)")
        }
    }

    /// KNOWN ISSUE `W40.fix-notes-block-marker-in-text`: a line of note text that reads as a block header
    /// is taken as one on the next read, so the line disappears from the text and the block splits in two.
    /// The format has no escape for it.
    @Test
    func blockHeaderLineInTextKnownIssue() throws {
        var rng = NoteFuzzRNG(seed: 1)
        var item = NoteFuzz.item(&rng, tricky: false)
        item.blocks = [Block(kind: .freeform, source: nil, markdown: "a\n<!-- block: freeform -->\nb\n", unknownHeaderFields: [])]
        item.trailingBodyRaw = nil
        let back = try FrontMatterCodec.decode(FrontMatterCodec.encode(item))
        withKnownIssue("W40.fix-notes-block-marker-in-text") {
            #expect(back.blocks.count == 1)
            #expect(back.blocks.first?.markdown == item.blocks[0].markdown)
        }
    }
}

// MARK: - Inputs

struct NoteFuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &self) }
    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
    mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
}

enum NoteFuzz {
    static let plain = ["Truman", "O'Brien", "Smith, J.", "Box 4 · Folder 2", "1958", "Q2", "ü日本", "a-b", "x: y",
                        "#1", "100%", "[draft]", "\"quoted\"", "true", "null", "- dash", "C:\\path"]
    static let tricky = ["-->", "<!-- block: freeform -->", "a \\\" b", "\\", "back\\\\slash\"", "---", " lead",
                         "trail ", "tab\there", "x #y", "{a: 1}", "'", "\"", "\\\"", "\u{FEFF}bom", "e\u{0301}"]

    static func string(_ rng: inout NoteFuzzRNG, tricky useTricky: Bool) -> String {
        let pool = useTricky ? plain + tricky : plain
        return (0..<rng.int(1...3)).map { _ in rng.pick(pool) }.joined(separator: rng.pick([" ", "", "-"]))
    }

    /// A front-matter value the codec documents as round-tripping: non-empty, no edge whitespace, no line break.
    static func token(_ rng: inout NoteFuzzRNG, tricky: Bool) -> String {
        let t = string(&rng, tricky: tricky).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "x" : t
    }

    static func item(_ rng: inout NoteFuzzRNG, tricky: Bool) -> Item {
        let secs = Double(1_500_000_000 + rng.int(0...50_000_000))
        var date: String?
        var precision: Item.DatePrecision?
        if rng.chance(0.7) {
            let d = randomDate(&rng)
            (date, precision) = Item.frontMatterDate(d)
        }
        let zotero: [ZoteroRef] = (0..<rng.int(0...2)).map { _ in
            let key = String((0..<8).map { _ in rng.pick(Array("ABCDEFGHJK23456789")) })
            let lib: ZoteroLibrary = rng.chance(0.5) ? .user : .group(rng.int(1...999_999))
            return ZoteroRef(selectLink: "zotero://select/library/items/\(key)", itemKey: key, library: lib,
                             kind: rng.chance(0.7) ? .item : .attachment,
                             parentKey: rng.chance(0.3) ? "PARENT12" : nil,
                             citation: rng.chance(0.6) ? token(&rng, tricky: tricky) : nil,
                             fetchedAt: rng.chance(0.4) ? Date(timeIntervalSince1970: secs + 5) : nil)
        }
        let sentWith = rng.chance(0.3) ? randomDate(&rng) : nil
        let blocks: [Block] = (0..<rng.int(0...4)).map { _ in
            let kind: Block.Kind = rng.pick([.freeform, .readerPage, .readerDoc, .zoteroItem, .notePassage])
            let source: SourceAnchor? = kind == .freeform ? nil : SourceAnchor(
                link: "archivereader://open?path=Box%204%2Ff.pdf&page=\(rng.int(1...9))",
                display: rng.chance(0.8) ? token(&rng, tricky: tricky) : nil,
                page: rng.chance(0.6) ? rng.int(1...400) : nil,
                thumbRef: nil, zoteroSelect: nil, noteRef: nil)
            // A text line that IS a block header is the known issue in `blockHeaderLineInTextKnownIssue`.
            let lines = (0..<rng.int(1...3)).map { _ in string(&rng, tricky: tricky) }
                .map { $0.hasPrefix("<!-- block:") ? "> " + $0 : $0 }
            return Block(kind: kind, source: source, markdown: lines.joined(separator: "\n") + "\n",
                         unknownHeaderFields: [])
        }
        return Item(
            id: UUID(),
            kind: rng.chance(0.5) ? .note : .extract,
            title: token(&rng, tricky: tricky),
            authors: (0..<rng.int(0...3)).map { _ in token(&rng, tricky: tricky) },
            date: date, datePrecision: precision, dateUncertain: date != nil && rng.chance(0.3),
            quality: rng.chance(0.5) ? rng.int(1...3) : nil,
            tags: Array(Set((0..<rng.int(0...4)).map { _ in token(&rng, tricky: tricky) })).sorted(),
            zotero: zotero, roundup: rng.chance(0.2),
            created: Date(timeIntervalSince1970: secs), modified: Date(timeIntervalSince1970: secs + 60),
            schema: 1, blocks: blocks,
            unknownFrontMatter: rng.chance(0.4) ? [UnknownKey(key: "x_extra", rawLines: ["x_extra: keep me"])] : [],
            trailingBodyRaw: rng.chance(0.4) ? "Leading prose.\n" : nil,
            sentWith: sentWith, sentWithUncertain: sentWith != nil && rng.chance(0.4),
            unparsedAdditionalDates: [],
            displayCalendar: rng.chance(0.3) ? rng.pick(DisplayCalendar.allCases.filter { $0 != .standard }) : nil)
    }

    static func randomDate(_ rng: inout NoteFuzzRNG) -> ArchiveDate {
        while true {
            let y = rng.int(100...2099)
            let d: ArchiveDate? = switch rng.int(0...3) {
            case 0: ArchiveDate(decade: y / 10 * 10)
            case 1: ArchiveDate(year: y)
            case 2: ArchiveDate(year: y, month: rng.int(1...12))
            default: ArchiveDate(year: y, month: rng.int(1...12), day: rng.int(1...31))
            }
            if let d { return d }
        }
    }

    /// Line- and character-level damage, plus nesting: a second fence, a block header inside a block, a
    /// whole copy of the front matter inside the body.
    static func damage(_ s: String, _ rng: inout NoteFuzzRNG) -> String {
        var lines = s.components(separatedBy: "\n")
        for _ in 0..<rng.int(1...3) {
            let n = lines.count
            let at = rng.int(0...(n - 1))
            switch rng.int(0...9) {
            case 0: lines = Array(lines.prefix(rng.int(1...n)))                                  // truncate at a line
            case 1: lines.remove(at: at)                                                         // drop a line
            case 2: lines.insert(lines[at], at: rng.int(0...n))                                  // duplicate a line
            case 3: lines[at] = "  " + lines[at]                                                 // nest it
            case 4: lines.insert(rng.pick(["---", "<!-- block: reader-page", "-->", "  - role: sent_with",
                                           "zotero:", "additional_dates:", "    date: 1958-02-30"]), at: rng.int(0...n))
            case 5: lines.insert(contentsOf: lines.prefix(rng.int(1...n)), at: rng.int(0...n))  // nested copy
            case 6:                                                                               // flip a character
                var c = Array(lines[at])
                if !c.isEmpty { c[rng.int(0...(c.count - 1))] = rng.pick(Array(":-\"'\\# \t\r>![{x0")) }
                lines[at] = String(c)
            case 7:                                                                               // truncate inside a line
                lines[at] = String(lines[at].prefix(rng.int(0...max(0, lines[at].count))))
            case 8: lines[at] = lines[at].replacingOccurrences(of: ": ", with: ":")
            default: lines[at] += rng.pick(["\r", " #c", " -->", "\"", "'"])
            }
        }
        return lines.joined(separator: rng.chance(0.1) ? "\r\n" : "\n")
    }

    static func expectSameNote(_ a: Item, _ b: Item, _ ctx: String) {
        #expect(a.id == b.id, "id — \(ctx)")
        #expect(a.kind == b.kind, "kind — \(ctx)")
        #expect(a.title == b.title, "title — \(ctx)")
        #expect(a.authors == b.authors, "authors — \(ctx)")
        #expect(a.date == b.date && a.datePrecision == b.datePrecision && a.dateUncertain == b.dateUncertain, "date — \(ctx)")
        #expect(a.quality == b.quality, "quality — \(ctx)")
        #expect(a.tags == b.tags, "tags — \(ctx)")
        #expect(a.zotero == b.zotero, "zotero — \(ctx)")
        #expect(a.roundup == b.roundup, "roundup — \(ctx)")
        #expect(a.created == b.created && a.modified == b.modified, "timestamps — \(ctx)")
        #expect(a.sentWith == b.sentWith && a.sentWithUncertain == b.sentWithUncertain, "sent with — \(ctx)")
        #expect(a.displayCalendar == b.displayCalendar, "display calendar — \(ctx)")
        #expect(a.unknownFrontMatter == b.unknownFrontMatter, "unknown keys — \(ctx)")
        #expect(a.trailingBodyRaw == b.trailingBodyRaw, "leading prose — \(ctx)")
        #expect(a.blocks.count == b.blocks.count, "block count — \(ctx)")
        for (x, y) in zip(a.blocks, b.blocks) {
            #expect(x.kind == y.kind && x.source == y.source && x.markdown == y.markdown, "block — \(ctx)")
        }
    }
}
