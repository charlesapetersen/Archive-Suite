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
    /// bullets), whitespace-trimmed, truncated to 80 chars on a word boundary; falls back to
    /// `"Extract <yyyy-MM-dd>"` when the snapshot is image-/whitespace-only.
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
    nonisolated static func defaultTitle(fromFirstLineOf blocks: [Block], fallbackDate: Date) -> String {
        let combined = blocks.map { $0.markdown }.joined(separator: "\n")
        for rawLine in BlockParser.splitLines(combined) {
            let cleaned = strippedTitleLine(String(rawLine))
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
        // Drop inline images entirely so an image-only line reads as empty and is skipped. The
        // grammar comes from `InlineImageMarkdown` so that an ESCAPED alt text
        // (`![Moore \[draft\]](assets/p1.png)`) is still recognised as an image — against the old
        // local pattern it survived stripping and became the extract's title
        // (W3.notes-thumb-line-duplicates-fu1).
        s = s.replacingOccurrences(of: InlineImageMarkdown.strippingPatternSource,
                                   with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        // Strip leading block markers: ATX headings, blockquotes, unordered + ordered list bullets.
        s = s.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)+"#,
                                   with: "", options: .regularExpression)
        // Strip inline emphasis / code markers.
        s = s.replacingOccurrences(of: #"[*_`]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
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
