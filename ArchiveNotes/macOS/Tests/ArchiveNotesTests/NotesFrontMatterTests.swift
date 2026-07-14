import Testing
import Foundation
@testable import ArchiveNotes

/// W8-S1 §1.1 — adversarial / property / fuzz coverage for the YAML front-matter codec.
///
/// The happy-path decode/encode cases are already pinned by `FrontMatterCodecTests`
/// (W2-S1) and `ZoteroFrontMatterRoundTripTests`. This suite adds what a feature wave
/// skips: a full all-known-keys round-trip, strict byte-for-byte unknown-key preservation,
/// truly-minimal graceful defaults, and a seeded fuzz loop proving the parser never crashes,
/// only throws typed errors, and never invents or drops data on any input it accepts.
@Suite("NotesFrontMatterTests — W8-S1 front-matter property/fuzz")
struct NotesFrontMatterTests {

    // MARK: - All-known-keys round-trip

    /// Every §5 front-matter field populated → encode → decode is struct-equal.
    @Test
    func roundTripPreservesAllKnownKeys() throws {
        // Whole-second dates so the ISO-8601 (`.withInternetDateTime`) round-trip is exact.
        let created = Date(timeIntervalSince1970: 1_600_000_000)
        let modified = Date(timeIntervalSince1970: 1_600_003_600)
        let fetched = Date(timeIntervalSince1970: 1_500_000_000)

        let item = Item(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .extract,
            title: "A Title: With Colon & \"Quotes\"",
            authors: ["Ada Lovelace", "Alan Turing"],
            date: "1968-03-25",
            datePrecision: .day,
            dateUncertain: true,
            quality: 4,
            tags: ["Foo", "Bar, Baz"],
            zotero: [
                ZoteroRef(selectLink: "zotero://select/library/items/ABCD1234",
                          itemKey: "ABCD1234", library: .user, kind: .item,
                          parentKey: nil, citation: "Lovelace, 1843", fetchedAt: fetched),
                ZoteroRef(selectLink: "zotero://select/groups/42/items/EFGH5678",
                          itemKey: "EFGH5678", library: .group(42), kind: .attachment,
                          parentKey: "PARENT99", citation: nil, fetchedAt: nil),
            ],
            roundup: true,
            created: created,
            modified: modified,
            schema: 1,
            blocks: [],
            unknownFrontMatter: [],
            trailingBodyRaw: nil
        )

        let decoded = try FrontMatterCodec.decode(FrontMatterCodec.encode(item))
        #expect(decoded == item)
    }

    // MARK: - Unknown-key preservation (never dropped)

    /// Unknown keys already in the encoder's canonical position (after `modified`, before the
    /// closing `---`) survive a decode→encode **byte-for-byte** — including a nested block.
    @Test
    func unknownKeysPreservedByteForByteWhenCanonical() throws {
        let fixture = """
        ---
        schema: 1
        id: aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
        kind: note
        title: Hello World
        roundup: false
        created: 2020-09-13T12:26:40Z
        modified: 2020-09-13T13:26:40Z
        future_flag: enabled
        experimental:
          - alpha: 1
          - beta: 2
        ---

        """
        let reencoded = FrontMatterCodec.encode(try FrontMatterCodec.decode(fixture))
        #expect(reencoded == fixture)
    }

    /// An unknown key in the MIDDLE of the front-matter is never dropped: the codec canonicalizes
    /// its position (to the end) but its raw lines survive verbatim and are stable thereafter.
    @Test
    func unknownKeysInMiddlePreservedThoughRepositioned() throws {
        let fixture = """
        ---
        schema: 1
        id: 12345678-1234-1234-1234-123456789abc
        kind: note
        title: Mid
        vendor_meta: keep-this-value
        roundup: false
        ---
        """
        let decoded = try FrontMatterCodec.decode(fixture)
        #expect(decoded.unknownFrontMatter.contains {
            $0.key == "vendor_meta" && $0.rawLines == ["vendor_meta: keep-this-value"]
        })

        let text1 = FrontMatterCodec.encode(decoded)
        #expect(text1.contains("vendor_meta: keep-this-value"))
        // Stable once canonicalized.
        let text2 = FrontMatterCodec.encode(try FrontMatterCodec.decode(text1))
        #expect(text1 == text2)
    }

    // MARK: - Graceful defaults

    /// A minimal front-matter (id/kind/title only) decodes with sane defaults for every optional.
    @Test
    func minimalFrontMatterDefaultsGracefully() throws {
        let fixture = """
        ---
        id: 00000000-0000-0000-0000-000000000001
        kind: note
        title: Minimal
        ---
        """
        let item = try FrontMatterCodec.decode(fixture)
        #expect(item.title == "Minimal")
        #expect(item.kind == .note)
        #expect(item.schema == 1)
        #expect(item.authors.isEmpty)
        #expect(item.tags.isEmpty)
        #expect(item.zotero.isEmpty)
        #expect(item.quality == nil)
        #expect(item.date == nil)
        #expect(item.datePrecision == nil)
        #expect(item.dateUncertain == false)
        #expect(item.roundup == false)
        #expect(item.blocks.isEmpty)
    }

    /// A missing/invalid `id` is the one hard failure — a typed error, never a crash.
    @Test
    func missingIdThrowsTypedError() {
        let noId = "---\nkind: note\ntitle: X\n---\n"
        #expect(throws: FrontMatterCodec.CodecError.self) {
            _ = try FrontMatterCodec.decode(noId)
        }
        let badId = "---\nid: not-a-uuid\nkind: note\ntitle: X\n---\n"
        #expect(throws: FrontMatterCodec.CodecError.self) {
            _ = try FrontMatterCodec.decode(badId)
        }
    }

    // MARK: - Characterization: edge Unicode-whitespace in scalars

    /// CHARACTERIZATION (not an endorsement): a scalar with a LEADING/TRAILING tab or non-U+0020
    /// Unicode-whitespace (e.g. NBSP) is normalized away on read — `decode` trims the value with
    /// `.whitespaces` (which includes tab + category-Zs), while `encode`'s `needsQuoting` only
    /// quotes a leading/trailing regular space, so such an edge char is not round-tripped.
    /// Interior whitespace and edge regular-spaces (which DO get quoted) are unaffected.
    /// Pinned so a future tightening of `needsQuoting` is an intentional, reviewed change.
    /// (Flagged to Morning Review 2026-07-14 — W8-S1.)
    @Test
    func leadingTrailingEdgeWhitespaceInScalarIsNormalized() throws {
        let uuid = "22222222-3333-4444-5555-666666666666"
        // Leading tab on the title value.
        let tabbed = "---\nid: \(uuid)\nkind: note\ntitle: \tTabbed\n---\n"
        #expect(try FrontMatterCodec.decode(tabbed).title == "Tabbed")
        // Edge regular-space DOES survive (encode quotes it).
        let spaced = Item(id: UUID(uuidString: uuid)!, kind: .note, title: "  Spaced  ",
                          authors: [], date: nil, datePrecision: nil, dateUncertain: false,
                          quality: nil, tags: [], zotero: [], roundup: false,
                          created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1),
                          schema: 1, blocks: [], unknownFrontMatter: [], trailingBodyRaw: nil)
        #expect(try FrontMatterCodec.decode(FrontMatterCodec.encode(spaced)).title == "  Spaced  ")
    }

    // MARK: - Fuzz: never crash, only typed errors

    /// Family A — thousands of pseudo-random byte blobs. The parser must never crash and must
    /// only ever surface a typed `CodecError` (most reject with `.missingFrontMatter`); any blob
    /// it happens to accept yields a valid UUID id.
    @Test
    func fuzzGarbageNeverCrashesOnlyTypedErrors() {
        var rng = SeededGenerator(seed: 0xF00D_CAFE_1234_5678)
        for _ in 0..<2000 {
            let blob = fuzzyString(maxLen: 800, using: &rng, allowNewlines: true, allowCR: true)
            do {
                _ = try FrontMatterCodec.decode(blob)
                // Accepted → decode guarantees a valid UUID; nothing else to assert here.
            } catch {
                #expect(error is FrontMatterCodec.CodecError,
                        "decode must only throw a typed CodecError, got \(type(of: error))")
            }
        }
    }

    /// Family B — structurally-corrupt fronts (BOM prefix, truncated fence, CRLF, tab indentation,
    /// duplicate keys, huge/emoji/control-char titles, injected unknown keys). Each either rejects
    /// with a typed error OR decodes; on any it accepts, a write→re-read is idempotent and the
    /// injected unknown marker key is never dropped.
    @Test
    func fuzzCorruptFrontsDecodeIdempotentlyOrThrowTyped() {
        var rng = SeededGenerator(seed: 0x1357_9BDF_2468_ACE0)
        for n in 0..<600 {
            let (blob, marker) = corruptFront(index: n, using: &rng)
            do {
                let item = try FrontMatterCodec.decode(blob)
                let text1 = FrontMatterCodec.encode(item)
                let text2 = FrontMatterCodec.encode(try FrontMatterCodec.decode(text1))
                #expect(text1 == text2, "write→re-read not idempotent for corrupt-front #\(n)")
                #expect(item.unknownFrontMatter.contains { $0.key == marker },
                        "injected unknown key '\(marker)' dropped for corrupt-front #\(n)")
            } catch {
                #expect(error is FrontMatterCodec.CodecError,
                        "decode must only throw a typed CodecError, got \(type(of: error))")
            }
        }
    }

    /// Family C — well-formed but fuzzy `Item`s (tricky titles/tags/authors/dates + unknown keys).
    /// The well-formed path must be byte-idempotent and never invent or drop a known field.
    @Test
    func fuzzWellFormedItemsRoundTripLosslessly() throws {
        var rng = SeededGenerator(seed: 0x0BAD_F00D_5EED_1111)
        for _ in 0..<400 {
            let item = randomItem(using: &rng)
            let text1 = FrontMatterCodec.encode(item)
            let item2 = try FrontMatterCodec.decode(text1)
            let text2 = FrontMatterCodec.encode(item2)
            #expect(text1 == text2)
            #expect(item2.id == item.id)
            #expect(item2.title == item.title)
            #expect(item2.kind == item.kind)
            #expect(item2.tags == item.tags)
            #expect(item2.authors == item.authors)
            #expect(item2.quality == item.quality)
            #expect(item2.unknownFrontMatter.count == item.unknownFrontMatter.count)
        }
    }

    // MARK: - Fuzz helpers

    /// splitmix64 — a tiny deterministic generator so fuzz failures reproduce exactly.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A fuzzy string over a palette of tricky characters (quotes, colons, brackets, emoji, em-dash,
    /// NBSP, control chars). `allowNewlines` adds `\n`; `allowCR` additionally adds a lone `\r`
    /// (only for pure-garbage blobs — a body with CR-soup exercises `\r\r\n` residual normalization,
    /// which is orthogonal to front-matter idempotency; see Morning Review 2026-07-14 W8-S1).
    private func fuzzyString(maxLen: Int, using rng: inout SeededGenerator,
                             allowNewlines: Bool, allowCR: Bool = false) -> String {
        var palette: [Character] = Array("abcXYZ 0123:,-[]{}\"'#*_`é—\u{00A0}😀\u{01}\t!?&|")
        if allowNewlines { palette.append("\n") }
        if allowCR { palette.append("\r") }
        let len = Int.random(in: 0...maxLen, using: &rng)
        var s = ""
        s.reserveCapacity(len)
        for _ in 0..<len { s.append(palette.randomElement(using: &rng)!) }
        return s
    }

    /// A single-line title with tricky interior chars but no edge Unicode-whitespace (see the
    /// characterization test) and no newlines — the shape the codec is designed to round-trip.
    private func fuzzyTitle(using rng: inout SeededGenerator) -> String {
        fuzzyString(maxLen: 40, using: &rng, allowNewlines: false)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A non-empty, whitespace-trimmed token for tags/authors (empty/edge-whitespace tokens are
    /// dropped or trimmed by the flow-list parser, so they don't belong in a round-trip fixture).
    private func fuzzyToken(using rng: inout SeededGenerator) -> String? {
        let t = fuzzyString(maxLen: 16, using: &rng, allowNewlines: false)
            .trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Build a corrupt-but-sometimes-decodable front-matter blob plus the name of the unknown key
    /// injected into it (asserted preserved on the decode-success path).
    private func corruptFront(index n: Int, using rng: inout SeededGenerator) -> (String, String) {
        let marker = "x_fuzz_\(n)"
        var lines = [
            "---",
            "schema: 1",
            "id: \(UUID().uuidString)",
            "kind: note",
            "title: \(fuzzyTitle(using: &rng))",
            "\(marker): keep-me",
            "roundup: false",
            "created: 2020-09-13T12:26:40Z",
            "modified: 2020-09-13T13:26:40Z",
        ]
        // Optional corruptions that keep the blob decodable.
        if Bool.random(using: &rng) { lines.insert("title: \(fuzzyTitle(using: &rng))", at: 5) } // duplicate key
        if Bool.random(using: &rng) { lines.append("nested_unknown:"); lines.append("  - a: 1") }
        if Bool.random(using: &rng) { lines.append("quality: \(Int.random(in: -3...99, using: &rng))") }
        lines.append("---")
        let body = fuzzyString(maxLen: 60, using: &rng, allowNewlines: true)
        var s = lines.joined(separator: "\n") + "\n" + body

        // Corruptions that may make it UNDECODABLE (exercise the typed-error branch).
        let pick = Int.random(in: 0...4, using: &rng)
        switch pick {
        case 0: s = "\u{FEFF}" + s                              // BOM prefix → missingFrontMatter
        case 1: s = s.replacingOccurrences(of: "\n---\n", with: "\n") // drop closing fence
        case 2: s = s.replacingOccurrences(of: "\n", with: "\r\n")    // CRLF (still decodable)
        default: break                                          // leave decodable
        }
        return (s, marker)
    }

    /// A well-formed random `Item` whose fields all round-trip by construction.
    private func randomItem(using rng: inout SeededGenerator) -> Item {
        let tags = (0..<Int.random(in: 0...4, using: &rng)).compactMap { _ in fuzzyToken(using: &rng) }
        let authors = (0..<Int.random(in: 0...3, using: &rng)).compactMap { _ in fuzzyToken(using: &rng) }
        let hasDate = Bool.random(using: &rng)
        let precisions: [Item.DatePrecision] = [.decade, .year, .month, .day]
        let unknownCount = Int.random(in: 0...2, using: &rng)
        let unknown = (0..<unknownCount).map { i in
            UnknownKey(key: "z_extra_\(i)", rawLines: ["z_extra_\(i): \(fuzzyToken(using: &rng) ?? "v")"])
        }
        let secs = 1_500_000_000 + Int.random(in: 0...50_000_000, using: &rng)
        return Item(
            id: UUID(),
            kind: Bool.random(using: &rng) ? .note : .extract,
            title: fuzzyTitle(using: &rng),
            authors: authors,
            date: hasDate ? "1970-06-15" : nil,
            datePrecision: hasDate ? precisions.randomElement(using: &rng) : nil,
            dateUncertain: Bool.random(using: &rng),
            quality: Bool.random(using: &rng) ? Int.random(in: 1...5, using: &rng) : nil,
            tags: tags,
            zotero: [],
            roundup: Bool.random(using: &rng),
            created: Date(timeIntervalSince1970: Double(secs)),
            modified: Date(timeIntervalSince1970: Double(secs + 60)),
            schema: 1,
            blocks: [],
            unknownFrontMatter: unknown,
            trailingBodyRaw: nil
        )
    }
}
