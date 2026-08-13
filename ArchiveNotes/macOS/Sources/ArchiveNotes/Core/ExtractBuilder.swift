import Foundation
import ArchiveCore

/// A snapshot block plus the inline-image bytes it references.
///
/// `Block` is a pure on-disk value type (BlockParser) with no field for pending bytes, so the
/// builder pairs them here until `createExtract`/`append` copies the bytes into the new extract's
/// own `assets/` via the audited `NoteStore.importAsset` and rewrites the markdown path. (The
/// 07-extracts.md sketch put `pendingAssets` on `Block`; the shipped `Block` has no such field, so
/// the bytes ride in this wrapper instead — same behavior, honest to the real type.)
struct ExtractPassageBlock: Sendable, Equatable {
    var block: Block
    /// Bare filename → PNG bytes, referenced as `assets/<filename>` in `block.markdown`.
    var pendingAssets: [String: Data]

    init(block: Block, pendingAssets: [String: Data] = [:]) {
        self.block = block
        self.pendingAssets = pendingAssets
    }
}

/// The read-only seam over a live note-editor selection.
///
/// W7-S1 is UI-free (plan §S1: "an injectable block-range map so it tests without a live
/// NSTextView"): the builder reads a selection only through this protocol. S2 supplies the real
/// `NSTextView`/`MarkdownBridge`-backed implementation; S1 tests supply a fake. `@MainActor`
/// because the real implementation touches AppKit text state.
@MainActor
protocol PassageSelectionSource {
    var sourceNoteId: UUID { get }
    var sourceTitle: String { get }
    var sourceDateDisplay: String { get }
    /// Selected character ranges (UTF-16) in the rendered text; empty / zero-length ⟹ no selection.
    var selectedRanges: [NSRange] { get }
    /// Rendered-text character span of each source block, keyed by block ordinal. Ranges are
    /// disjoint; order need not be sorted (the builder orders results by covered-range position).
    var blockRanges: [(blockIndex: Int, range: NSRange)] { get }
    /// Snapshot a covered sub-range into CommonMark + the inline-image bytes it references (keyed by
    /// bare filename). A value copy — the source note is never mutated.
    func snapshotMarkdown(in range: NSRange) -> (markdown: String, assets: [String: Data])
}

/// Turns a note-editor selection (or a pasted passage payload) into extract `Block`s and persists
/// a new `Item(kind: .extract)`, or appends to an existing extract (cross-note segmentation, §D7).
///
/// The only persistent writes go through W2's already-audited `NoteStore` (`create`/`save`/
/// `importAsset`) — W7 adds no new file-writing choke-point, which is what keeps it Tier-1.
/// Organization-graph membership (which folder a new extract lands in) is *not* a `NoteStore`
/// concern; the S2 UI wiring adds the membership row through `NotesModel`/`OrganizationStore`.
@MainActor
struct ExtractBuilder {
    let store: NoteStore
    /// Injectable clock for deterministic tests.
    let now: () -> Date

    init(store: NoteStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    // MARK: - Selection / payload → passage blocks (pure; no store access)

    /// Snapshot the current selection into one passage block per covered source block (plan
    /// §Algorithm). Every covered block yields a `note-passage` anchor to `(sourceNoteId, ordinal)`
    /// — *regardless of the source block's own kind* — because provenance is "this passage came
    /// from note X, block b". Empty selection ⟹ `[]`.
    static func passageBlocks(fromSelectionIn source: PassageSelectionSource) -> [ExtractPassageBlock] {
        let ranges = source.selectedRanges.filter { $0.length > 0 }
        guard !ranges.isEmpty else { return [] }

        // (documentPosition, passage) so discontiguous multi-selection concatenates in doc order.
        var covered: [(position: Int, passage: ExtractPassageBlock)] = []
        for selection in ranges {
            for entry in source.blockRanges {
                let hit = NSIntersectionRange(selection, entry.range)
                guard hit.length > 0 else { continue }
                let snapshot = source.snapshotMarkdown(in: hit)
                let anchor = SourceAnchor.notePassage(sourceNoteId: source.sourceNoteId,
                                                      sourceBlockIndex: entry.blockIndex,
                                                      sourceTitle: source.sourceTitle,
                                                      sourceDateDisplay: source.sourceDateDisplay)
                let block = Block(kind: .notePassage, source: anchor,
                                  markdown: snapshot.markdown, unknownHeaderFields: [])
                covered.append((hit.location,
                                ExtractPassageBlock(block: block, pendingAssets: snapshot.assets)))
            }
        }
        return covered.sorted { $0.position < $1.position }.map { $0.passage }
    }

    /// Build passage blocks from a pasted `NotesPassagePayload` (copy-from-Notes → paste-into-Extract).
    /// Pure (no editor / main-actor state) so it is `nonisolated` and unit-testable off the main actor.
    nonisolated static func passageBlocks(from payload: NotesPassagePayload) -> [ExtractPassageBlock] {
        payload.segments.map { segment in
            let anchor = SourceAnchor.notePassage(sourceNoteId: payload.sourceNoteId,
                                                  sourceBlockIndex: segment.sourceBlockIndex,
                                                  sourceTitle: payload.sourceTitle,
                                                  sourceDateDisplay: payload.sourceDateDisplay)
            let block = Block(kind: .notePassage, source: anchor,
                              markdown: segment.markdown, unknownHeaderFields: [])
            return ExtractPassageBlock(block: block, pendingAssets: segment.assetPNGs)
        }
    }

    /// Build the `com.archivenotes.passage` copy payload for the current note selection, or nil when
    /// there is no non-empty selection (07-extracts §5). The one place the copy path turns a live
    /// selection into durable provenance; pure over the seam so it unit-tests with a fake source. The
    /// segment ordinal is recovered from the anchor `passageBlocks` already built (`#block-<n>`).
    static func passagePayload(fromSelectionIn source: PassageSelectionSource) -> NotesPassagePayload? {
        let passages = passageBlocks(fromSelectionIn: source)
        guard !passages.isEmpty else { return nil }
        let segments = passages.map { p in
            NotesPassagePayload.Segment(
                sourceBlockIndex: p.block.source?.notePassageTarget?.block ?? 0,
                markdown: p.block.markdown,
                assetPNGs: p.pendingAssets)
        }
        return NotesPassagePayload(sourceNoteId: source.sourceNoteId,
                                   sourceTitle: source.sourceTitle,
                                   sourceDateDisplay: source.sourceDateDisplay,
                                   segments: segments)
    }

    /// The body markdown to insert when pasting a passage payload into an extract editor (07-extracts
    /// §5): the payload's segments as note-passage blocks, run through the extracts-reference-notes-only
    /// coercion, serialized to the on-disk `<!-- block: -->` form so `MarkdownBridge.parse` renders the
    /// chip + body identically to a saved-then-reloaded extract. Empty when the payload has no segments.
    ///
    /// This pure variant inserts the image *references* only. The live paste handler must instead use
    /// `pastedExtractMarkdown(from:importingAssetsVia:)` so the payload's inline-image BYTES are copied
    /// into the extract's own `assets/` — otherwise a pasted image dangles as a missing-asset placeholder.
    nonisolated static func pastedExtractMarkdown(from payload: NotesPassagePayload) -> String {
        serializedExtractBody(passageBlocks(from: payload).map { $0.block })
    }

    /// Extract-paste body markdown that ALSO imports each segment's inline-image bytes into the target
    /// extract's own `assets/` (07-extracts §5 — the paste analogue of `persist(_:into:)`). For every
    /// pending asset, `importAsset(bytes, bareName)` reserves+writes a copy (no-overwrite guard) and
    /// returns the stored `assets/<name>` ref; when the store disambiguated a name-collision
    /// (`stored != assets/<bare>`) the block markdown ref is rewritten to the stored name so the inserted
    /// text points at the file that actually landed. A nil return (import failed / no target item) leaves
    /// that one ref at the original name — a missing-asset placeholder, never a crash — without aborting
    /// the rest of the paste. `@MainActor` because the production importer (`ItemAssetStore.addAsset`) is
    /// main-actor-isolated.
    @MainActor
    static func pastedExtractMarkdown(from payload: NotesPassagePayload,
                                      importingAssetsVia importAsset: (Data, String) -> String?) -> String {
        let imported: [Block] = passageBlocks(from: payload).map { passage in
            var block = passage.block
            for (name, bytes) in passage.pendingAssets {
                let bare = (name as NSString).lastPathComponent
                guard let stored = importAsset(bytes, bare) else { continue }
                let originalRef = "assets/\(bare)"
                if stored != originalRef {
                    // Spelled by the grammar owner, not interpolated: a name needing the
                    // angle-bracket destination (`assets/photo (1).png`) is written `](<…>)`, and a
                    // hand-rolled `](\(ref))` would silently fail to find it — leaving the copy
                    // referenced at the ORIGINAL name, i.e. a missing asset (W3.notes-image-dest-paren).
                    block.markdown = block.markdown.replacingOccurrences(
                        of: InlineImageMarkdown.destinationLiteral(originalRef),
                        with: InlineImageMarkdown.destinationLiteral(stored))
                }
            }
            return block
        }
        return serializedExtractBody(imported)
    }

    /// Shared tail for both `pastedExtractMarkdown` overloads: coerce to the extracts-reference-notes-only
    /// invariant, then serialize to the on-disk block form; "" when nothing survives coercion.
    nonisolated private static func serializedExtractBody(_ blocks: [Block]) -> String {
        let coerced = coercedToNotesOnly(blocks)
        guard !coerced.isEmpty else { return "" }
        return BlockParser.serialize(leadingText: nil, blocks: coerced)
    }

    // MARK: - Extract-references-notes-only invariant (the single choke-point, §Risks)

    /// Coerce any block that is NOT a resolvable note-passage (a reader-page/-doc, a zotero-*, or a
    /// note-passage with a malformed target) into a plain `freeform` block with no source, and strip
    /// any block header nested *inside* a block's markdown. Both the paste path and `persist` (i.e.
    /// every durable extract write) route through here, so an outside-document source cannot attach to
    /// an extract at either level (extracts reference NOTES only — §D7).
    nonisolated static func coercedToNotesOnly(_ blocks: [Block]) -> [Block] {
        blocks.map { block in
            let markdown = flattenedNestedHeaders(block.markdown)
            if block.kind == .notePassage, block.source?.notePassageTarget != nil {
                var kept = block
                kept.markdown = markdown
                return kept
            }
            return Block(kind: .freeform, source: nil,
                         markdown: markdown, unknownHeaderFields: [])
        }
    }

    /// Drop `<!-- block: … -->` headers nested inside ONE block's markdown, keeping every scrap of
    /// text (W3.notes-extract-smuggles-a-source-header).
    ///
    /// Kind coercion above inspects the block list, so it is blind one level down — and a header at a
    /// line start inside a block's markdown is not inert text: `BlockParser.parse` splits on it, so on
    /// reload it becomes a *real* foreign block inside the extract. The root cause was
    /// `EditorPassageSource.snapshotMarkdown` re-serializing the source note's own chip (fixed there,
    /// where the chip is still an attribute rather than text); this is the choke-point half, so the
    /// invariant does not rest on every future producer of a passage markdown being careful.
    /// `BlockParser` is the authority on what counts as a header, so the split is delegated to it and
    /// cannot drift from the reader.
    nonisolated private static func flattenedNestedHeaders(_ markdown: String) -> String {
        let (leading, nested) = BlockParser.parse(markdown)
        guard !nested.isEmpty else { return markdown }   // the common path: no header, byte-identical
        var out = leading ?? ""
        for block in nested where !block.markdown.isEmpty {
            // Same authority on what ends a line as everywhere else — `hasSuffix("\n")` is false for
            // CR/CRLF-terminated text and would insert a blank line (`W3.notes-cr-line-start`).
            if !out.isEmpty, !BlockParser.endsWithLineTerminator(out) { out += "\n" }
            out += block.markdown
        }
        return out
    }

    // MARK: - Default title

    /// First non-empty snapshot line, stripped of Markdown markers (`#`, `*`, `_`, `>`, list
    /// bullets), with inline images dropped and inline LINKS reduced to their label,
    /// **with its backslash escapes resolved**, whitespace-trimmed, truncated to 80 chars on
    /// a word boundary; falls back to `"Extract <yyyy-MM-dd>"` when the snapshot is
    /// image-/whitespace-only.
    ///
    /// The unescaping is not cosmetic: this string is written to the extract's `title:` front matter
    /// *and* projected into its `.md` FILENAME (`NoteStore.sanitizedTitle` maps only `/` and `:`), so a
    /// backslash left unresolved lands on disk. Code spans and fenced blocks are exempt, because their
    /// content is emitted raw — see `strippedInlineMarkers` for the whole rule
    /// (`W3.notes-image-label-trailing-backslash`).
    ///
    /// **Two OUT-OF-SCOPE spellings of a URL, decided in `W3.notes-extract-title-link-markdown`.** An
    /// autolink (`<https://…>`) keeps its angle brackets and a bare URL is already plain text — neither
    /// is reachable from the emitter (`MarkdownBridge.serialize` writes every link as `[text](url)`),
    /// and CommonMark renders both AS the URL, so reducing them would trade `<https---x>.md` for
    /// `https---x.md`. The ugliness there is `sanitizedTitle`'s mapping of `:` and `/`, not this pass.
    ///
    /// **Known divergence, pre-existing in shape and now shared by links:** the image and link passes
    /// are regexes over the whole line, so a reference inside a CODE SPAN is stripped/reduced even
    /// though CommonMark renders it literally (`` `[a](b)` `` titles as `a`, not `[a](b)`). Only the
    /// escape/emphasis half of the pass knows about code spans. Tracked as
    /// `W3.notes-extract-title-code-span-references`.
    ///
    /// Takes the blocks as **persisted** (i.e. post-`coercedToNotesOnly`), not the raw passages: a
    /// `<!-- block: …` line nested in the markdown is not title material, and reading it as one put
    /// the smuggled header back into the front matter even once the body was clean
    /// (W3.notes-extract-smuggles-a-source-header).
    ///
    /// The line split goes through `BlockParser.splitLines` — the same authority the rest of this family
    /// routes through — because Swift compares GRAPHEMES: `"\r\n"` is not `"\n"` and a lone `"\r"` is not
    /// either, so `split(separator: "\n")` did not split a CR/CRLF snapshot at all and titled the extract
    /// with the first 80 characters of the WHOLE passage (`W3.notes-extract-title-line-split`). PDF text
    /// extraction hands back both forms. Note the block seam is the same bug: the markdowns are joined
    /// with `"\n"`, so a block ending in a lone `"\r"` makes a `"\r\n"` grapheme at the join.
    /// A FENCED CODE BLOCK is carried across lines here rather than inside `strippedTitleLine`,
    /// because a fence is the one piece of this grammar a single line cannot decide. Its content is
    /// title material — the fence lines themselves strip to nothing, so the first code line is what
    /// names the extract — and inside it there are no markers and no escapes to resolve, so the line
    /// is taken VERBATIM. `MarkdownBridge` emits code-block runs raw (`inCodeBlock` → `result +=
    /// runText`), so anything else would rewrite the operator's own code into the filename
    /// (W3.notes-image-label-trailing-backslash). An unclosed fence runs to the end, as CommonMark says.
    nonisolated static func defaultTitle(fromFirstLineOf blocks: [Block], fallbackDate: Date) -> String {
        let combined = blocks.map { $0.markdown }.joined(separator: "\n")
        var fence: (marker: Character, length: Int)?
        for rawLine in BlockParser.splitLines(combined) {
            let line = String(rawLine)
            if let delimiter = fenceDelimiter(line) {
                if let open = fence {
                    if delimiter.marker == open.marker, delimiter.length >= open.length { fence = nil }
                } else {
                    fence = delimiter
                }
                continue
            }
            let cleaned = fence == nil ? strippedTitleLine(line)
                                       : line.trimmingCharacters(in: .whitespaces)
            if !cleaned.isEmpty { return truncateOnWordBoundary(cleaned, max: 80) }
        }
        return "Extract " + isoDay(fallbackDate)
    }

    // MARK: - Persistence

    /// Create a brand-new extract from snapshot passages and persist it (new UUID folder + `.md` +
    /// copied assets). The extract owns its **own** date (default = creation day, `.day` precision;
    /// user-editable later via the W6 date control). Returns the created `Item`.
    func createExtract(from passages: [ExtractPassageBlock]) async throws -> Item {
        let id = UUID()
        let when = now()
        let blocks = try await persist(passages, into: id)
        let (date, precision) = Item.normalizedDate(Self.isoDay(when), precision: .day)
        let item = Item(id: id,
                        kind: .extract,
                        title: Self.defaultTitle(fromFirstLineOf: blocks, fallbackDate: when),
                        authors: [],
                        date: date,
                        datePrecision: precision,
                        dateUncertain: false,
                        quality: nil,
                        tags: [],
                        zotero: [],
                        roundup: false,
                        created: when,
                        modified: when,
                        schema: 1,
                        blocks: blocks,
                        unknownFrontMatter: [],
                        trailingBodyRaw: nil)
        _ = try await store.create(item)
        return item
    }

    /// Convenience: snapshot the selection and create the extract in one call.
    func createExtract(fromSelectionIn source: PassageSelectionSource) async throws -> Item {
        try await createExtract(from: Self.passageBlocks(fromSelectionIn: source))
    }

    /// Segmentation (§D7): append passages to an EXISTING extract (which may already link to other
    /// notes) and re-save. Assets are copied into that extract's own `assets/`. Returns the extract as
    /// written, so the caller re-indexes exactly what landed instead of re-reading the store.
    ///
    /// **W23.h2 — the append is one atomic `withItem` transaction.** It used to be
    /// `load` → copy assets → `save`, with the asset copies (each its own `await`) sitting between the
    /// read and the write: an ordinary metadata edit racing an append would be silently dropped by
    /// whichever whole-item save landed second. The asset copies stay *outside* the transaction — they
    /// write into `assets/`, never the `.md`, and don't depend on the item's current state.
    @discardableResult
    func append(toExtract id: UUID, passages: [ExtractPassageBlock]) async throws -> Item {
        // Pre-flight existence probe: `persist` creates `<item>/assets/` on demand, so appending to a
        // missing extract would otherwise leave a phantom item dir with no `.md`. `mdURL` only locates
        // the `.md` (no read, no parse) — it is purely an early-out that keeps the old fail-fast
        // contract; the authoritative read is the one inside the transaction below, so a delete racing
        // the probe still fails the append rather than resurrecting the item.
        _ = try await store.mdURL(for: id)
        let blocks = try await persist(passages, into: id)
        let when = now()
        return try await store.withItem(id) { item in
            item.blocks.append(contentsOf: blocks)
            item.modified = when
        }.item
    }

    /// Convenience: snapshot the selection and append it to an existing extract.
    @discardableResult
    func append(toExtract id: UUID, fromSelectionIn source: PassageSelectionSource) async throws -> Item {
        try await append(toExtract: id, passages: Self.passageBlocks(fromSelectionIn: source))
    }

    // MARK: - Internal

    /// Copy each passage's inline-image bytes into the target item's `assets/` (via the audited
    /// `NoteStore.importAsset`), rewriting the block markdown when the store disambiguated the
    /// stored filename. Returns the blocks with resolved asset paths, run through
    /// `coercedToNotesOnly` — this is the one path `createExtract` and `append` share, so putting the
    /// §D7 invariant here means no durable extract write can bypass it (W3.notes-extract-smuggles-a-
    /// source-header). For blocks built by `passageBlocks` the coercion is the identity; it bites only
    /// when a caller hands over a block that is not a resolvable note passage.
    private func persist(_ passages: [ExtractPassageBlock], into id: UUID) async throws -> [Block] {
        var result: [Block] = []
        result.reserveCapacity(passages.count)
        for passage in passages {
            var block = passage.block
            for (name, bytes) in passage.pendingAssets {
                let bare = (name as NSString).lastPathComponent
                let stored = try await store.importAsset(bytes, preferredName: bare, into: id)
                let originalRef = "assets/\(bare)"
                if stored != originalRef {
                    // Same re-key, same reason as `pastedExtractMarkdown` — through the grammar owner
                    // so an angle-bracketed destination is found too (W3.notes-image-dest-paren).
                    block.markdown = block.markdown.replacingOccurrences(
                        of: InlineImageMarkdown.destinationLiteral(originalRef),
                        with: InlineImageMarkdown.destinationLiteral(stored))
                }
            }
            result.append(block)
        }
        return Self.coercedToNotesOnly(result)
    }

    // MARK: - Pure text helpers

    /// SPEC day string ("yyyy-MM-dd"), locale/timezone-stable via the Gregorian calendar.
    nonisolated static func isoDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 1, c.day ?? 1)
    }

    nonisolated private static func strippedTitleLine(_ line: String) -> String {
        var s = line
        s = s.trimmingCharacters(in: .whitespaces)
        // Strip leading block markers: ATX headings, blockquotes, unordered + ordered list bullets.
        s = s.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)+"#,
                                   with: "", options: .regularExpression)
        s = strippedInlineMarkers(s)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Drop inline images, reduce links to their labels, then drop emphasis markers and resolve
    /// backslash escapes. Code spans are protected before the reference passes, because their contents
    /// are literal CommonMark text rather than title markup.
    ///
    /// **W3.notes-image-label-trailing-backslash.** This used to be `[*_`]` → `""` with no unescaping
    /// at all, so `MarkdownBridge.escapeMarkdown`'s own output came back through it wrong in both
    /// directions, and the result is durable — it becomes the extract's `title:` front matter *and*,
    /// via `NoteStore.sanitizedTitle` (which maps only `/` and `:`), its `.md` filename:
    ///
    /// - a typed `Real [Title]` is written `Real \[Title\]` and titled the extract with the
    ///   backslashes in it;
    /// - a typed `Real *not emphasis*` is written `Real \*not emphasis\*`, and deleting the markers
    ///   unconditionally *kept the backslashes that protected them* — `Real \not emphasis\`.
    ///
    /// **A CODE SPAN is exempt from both, and that is not a nicety.** `MarkdownBridge.wrapInlineCode`
    /// writes the operator's text into backticks *raw* — it escapes nothing, because CommonMark
    /// processes neither escapes nor emphasis inside a code span. Unescaping there would delete a
    /// backslash the operator actually typed: a first line of `` `re.sub(r'\.', '')` `` would be
    /// titled — and filed on disk — as `re.sub(r'.', '')`. The old pass had the mirror-image bug, in
    /// that it deleted `*` and `_` from code content, so honouring the span fixes that too.
    ///
    /// Outside a code span this is CommonMark's own reading of the line: the plain text any other
    /// viewer renders. Two deliberate departures, both unreachable from the emitter and both kept for
    /// a title's sake — a line ending in a lone backslash keeps it (CommonMark reads a hard line break
    /// and renders nothing), and an *unmatched* backtick run is dropped as a stray marker rather than
    /// shown literally.
    ///
    /// Images go first because a link pass would otherwise eat an image's `[alt](path)` suffix and
    /// leave a `!`; links then reduce to their labels. Both patterns come from the grammar owner.
    /// That work happens only after `protectingCodeSpans` has replaced code content with collision-free
    /// sentinels, so a reference inside code reaches the filename verbatim
    /// (`W3.notes-extract-title-code-span-references`). The escape half repeats
    /// `InlineImageMarkdown.unescapeAlt`'s loop, and stopped being able to share it once code spans
    /// entered — but the rule deciding *which* backslashes are escapes is sourced from the grammar
    /// owner (`isEscapable`), so the two cannot drift on that.
    nonisolated private static func strippedInlineMarkers(_ line: String) -> String {
        let (protected, codeSpans) = protectingCodeSpans(in: line)
        var s = protected
        s = s.replacingOccurrences(of: InlineImageMarkdown.strippingPatternSource,
                                   with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: InlineImageMarkdown.linkPatternSource,
                                   with: "$1", options: .regularExpression)
        s = strippedNonCodeInlineMarkers(s)
        for (token, content) in codeSpans {
            s = s.replacingOccurrences(of: token, with: content)
        }
        return s
    }

    /// Replace each matched code span with a token that cannot occur in this line. Regexes can then
    /// work on the non-code portions as one string, preserving image-before-link ordering even for an
    /// image wrapped in a link. An escaped backtick stays in ordinary text and an unmatched run stays
    /// for `strippedNonCodeInlineMarkers` to discard, matching the previous title behaviour.
    nonisolated private static func protectingCodeSpans(in line: String) ->
        (protected: String, codeSpans: [(token: String, content: String)]) {
        let chars = Array(line)
        var sentinel = "\u{E000}"
        while line.contains(sentinel) { sentinel.append("\u{E000}") }

        var protected = ""
        protected.reserveCapacity(line.count)
        var codeSpans: [(token: String, content: String)] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "\\" {
                protected.append(ch)
                i += 1
                if i < chars.count {
                    protected.append(chars[i])
                    i += 1
                }
            } else if ch == "`" {
                let run = backtickRunLength(chars, at: i)
                if let close = closingBacktickRun(chars, after: i + run, length: run) {
                    let token = "\(sentinel)\(codeSpans.count)\(sentinel)"
                    codeSpans.append((token, codeSpanContent(chars[(i + run)..<close])))
                    protected += token
                    i = close + run
                } else {
                    protected += String(repeating: "`", count: run)
                    i += run
                }
            } else {
                protected.append(ch)
                i += 1
            }
        }
        return (protected, codeSpans)
    }

    /// The marker and escape pass after matched code spans have been protected. It deliberately has
    /// no code-span branch: any remaining backtick run is unmatched and therefore a stray marker.
    nonisolated private static func strippedNonCodeInlineMarkers(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        var afterBackslash = false
        while i < chars.count {
            let ch = chars[i]
            if afterBackslash {
                // An escaped marker is literal text: keep it, drop the backslash that said so.
                if !InlineImageMarkdown.isEscapable(ch) { out.append("\\") }
                out.append(ch)
                afterBackslash = false
                i += 1
            } else if ch == "\\" {
                afterBackslash = true
                i += 1
            } else if ch == "`" {
                i += backtickRunLength(chars, at: i)
            } else if ch == "*" || ch == "_" {
                i += 1
            } else {
                out.append(ch)
                i += 1
            }
        }
        // A hand-edited line can end on a lone backslash; the emitter never writes one.
        if afterBackslash { out.append("\\") }
        return out
    }

    /// Length of the backtick run starting at `i`.
    nonisolated private static func backtickRunLength(_ chars: [Character], at i: Int) -> Int {
        var n = 0
        while i + n < chars.count, chars[i + n] == "`" { n += 1 }
        return n
    }

    /// Index of the next backtick run of *exactly* `length`, at or after `from`; nil if there is none.
    /// Exactly, not at-least — that is what lets a single `` ` `` sit inside a `` … `` span, which is
    /// precisely how `wrapInlineCode` writes text that itself contains a backtick.
    nonisolated private static func closingBacktickRun(_ chars: [Character],
                                                       after from: Int,
                                                       length: Int) -> Int? {
        var i = from
        while i < chars.count {
            guard chars[i] == "`" else { i += 1; continue }
            let run = backtickRunLength(chars, at: i)
            if run == length { return i }
            i += run
        }
        return nil
    }

    /// A code span's content: CommonMark strips one leading and one trailing space when both are there
    /// and the content is not all spaces — exactly the pair `wrapInlineCode` adds when it widens the
    /// fence for a backtick in the text.
    nonisolated private static func codeSpanContent(_ slice: ArraySlice<Character>) -> String {
        let s = String(slice)
        guard s.count >= 2, s.hasPrefix(" "), s.hasSuffix(" "), s.contains(where: { $0 != " " })
        else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// A fenced-code delimiter line — three or more backticks or tildes, indented at most three
    /// spaces — as `(marker, run length)`, or nil. A backtick fence's info string may not itself
    /// contain a backtick, which is what keeps an ordinary `` `a` `` line from opening a block.
    nonisolated private static func fenceDelimiter(_ line: String) -> (marker: Character, length: Int)? {
        var s = Substring(line)
        var indent = 0
        while indent < 3, s.first == " " { s = s.dropFirst(); indent += 1 }
        guard let marker = s.first, marker == "`" || marker == "~" else { return nil }
        let length = s.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        if marker == "`", s.dropFirst(length).contains("`") { return nil }
        return (marker, length)
    }

    nonisolated private static func truncateOnWordBoundary(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let cut = s.index(s.startIndex, offsetBy: max)
        let head = String(s[..<cut])
        if let lastSpace = head.lastIndex(of: " ") {
            let trimmed = String(head[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return head.trimmingCharacters(in: .whitespaces)
    }
}
