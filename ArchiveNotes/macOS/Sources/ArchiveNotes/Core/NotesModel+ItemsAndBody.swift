import Foundation
import ArchiveCore

// MARK: - Items, extracts, metadata, body & Zotero edits (W49.notes-model-split)

extension NotesModel {
    // MARK: New item (blank or from a template) (W6-S6)

    /// Create a new item of `kind` in `folderId` (`nil` ⟹ the system default: Inbox for a note,
    /// Extracts for an extract, §16.6), instantiated from `templateId` when given: the template's
    /// front-matter defaults (title/date/quality/tags/roundup) + body are cloned into a fresh
    /// item (new UUID, fresh created/modified). Returns the new item id (nil on failure / no store).
    @discardableResult
    func newItem(kind: Item.Kind, in folderId: UUID?, from templateId: UUID?) async -> UUID? {
        guard let noteStore else { return nil }
        // Before the file is written: with the folders read-only, its filing would be refused and every
        // press of New would leave another unfiled note behind (W40.fix-notes-index-failure-empty).
        guard !refuseWhileFoldersReadOnly("create the note") else { return nil }
        var item: Item
        if let templateId {
            do { item = try await noteStore.loadTemplate(templateId) }
            catch { report(error, "read the template"); return nil }
            item.id = UUID()
            item.kind = kind
            item.created = Date(); item.modified = Date()
        } else {
            item = blankItem(kind: kind, title: "")
        }
        let target = folderId ?? (kind == .extract ? organization.extractsHomeFolderId
                                                    : OrganizationStore.inboxFolderId)
        do {
            let ref = try await noteStore.create(item)
            try await file(ItemTransaction(item: item, ref: ref), into: [target],
                           noteStore: noteStore, tagSource: "the template's")
            return item.id
        } catch { report(error, "create the note"); return nil }
    }

    /// Duplicate Note (W49.notes-polish-small): a copy titled "<title> copy" with the note's fields, body and
    /// images, filed in the same folders as the original (the kind's default folder when it is in none).
    /// Returns the copy's id (nil on failure / no store).
    @discardableResult
    func duplicateNote(_ id: UUID) async -> UUID? {
        guard let noteStore else { return nil }
        guard !refuseWhileFoldersReadOnly("duplicate the note") else { return nil }
        guard let summary = allItems.first(where: { $0.id == id }) else { return nil }
        let folders = organization.memberships.filter { $0.itemId == id }.map(\.folderId)
        let targets = folders.isEmpty
            ? [summary.kind == .extract ? organization.extractsHomeFolderId : OrganizationStore.inboxFolderId]
            : folders
        do {
            let created = try await noteStore.duplicate(id)
            try await file(created, into: targets, noteStore: noteStore, tagSource: "the original's")
            return created.item.id
        } catch { report(error, "duplicate the note"); return nil }
    }

    /// File a note just written to the store: add it to `folders` and index it, then refresh the lists.
    /// Shared by New and Duplicate. (W49.storage-finder-drop-mirror: front-matter YAML is the sole home; no Finder
    /// tags are mirrored onto `.md` files.)
    private func file(_ written: ItemTransaction, into folders: [UUID], noteStore: NoteStore,
                      tagSource: String) async throws {
        _ = (noteStore, tagSource)
        let item = written.item
        let tx = written
        for folder in folders { try await organization.addMembership(item: item.id, folder: folder) }
        // W9.e2-zotero: upsert the new row inline, as createExtract does. Nothing watches the store,
        // so without it the new note stayed out of every list until the next launch's index build.
        // Non-fatal: the note is already written and filed, so still select it if only the cache fails.
        if let index {
            do { try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)]) }
            catch { report(error, "index the new note") }
        }
        await reloadItems()
        rebuild()
        adoptMirrorFailure()
    }

    // MARK: Extracts (W7-S2 — create / append from a note-editor selection)
    //
    // The extract experience mints a new, independently-editable `Item(kind: .extract)` holding a
    // SNAPSHOT copy of a note passage plus a durable note-passage provenance link (07-extracts §2/§5).
    // Persistence goes ONLY through the audited `NoteStore` (via `ExtractBuilder`) + the atomic
    // `OrganizationStore` membership write — W7 adds no new file-writing choke-point (keeps it Tier-1).
    // The source note is READ-ONLY at snapshot; the archival corpus is never touched (Prime Directive
    // #1). These upsert the one new/changed index row inline so the extract appears in the Extracts
    // window's list immediately (no full re-index pass needed) — same idiom as `mutateItem` and
    // `newItem`.

    /// Create a new extract from a live note selection and file it into the Extracts home folder
    /// (or `folderId`). Returns the new extract's id (nil on empty selection / no store / failure).
    /// Both windows observe `allItems`, so the Extracts window features the new extract at once.
    @discardableResult
    func createExtract(from source: PassageSelectionSource, into folderId: UUID? = nil) async -> UUID? {
        guard let noteStore else { return nil }
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn: source)
        guard !passages.isEmpty else {
            statusMessage = "Select text in a note to make an extract."
            return nil
        }
        guard !refuseWhileFoldersReadOnly("make the extract") else { return nil }
        do {
            let created = try await ExtractBuilder(store: noteStore).createExtract(from: passages)
            let projectionTx = try await noteStore.currentItemTransaction(created.id)
            try await organization.addMembership(item: created.id,
                                                 folder: folderId ?? organization.extractsHomeFolderId)
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: projectionTx.item,
                                                          mtime: projectionTx.ref.mtime)])
            }
            await reloadItems()
            rebuild()
            adoptMirrorFailure()
            // W14.4(b): route the new extract through the open channel so the Extracts window selects
            // it (and, if open, raises itself) — the extract is no longer silently filed into the list.
            openItem(id: created.id, block: nil)
            return created.id
        } catch { report(error, "create the extract"); return nil }
    }

    /// Append a live note selection to an EXISTING extract (cross-note segmentation, §D7). No-op on an
    /// empty selection. The source note is never mutated; errors surface via `statusMessage`.
    func appendToExtract(_ id: UUID, from source: PassageSelectionSource) async {
        guard let noteStore else { return }
        let passages = ExtractBuilder.passageBlocks(fromSelectionIn: source)
        guard !passages.isEmpty else {
            statusMessage = "Select text in a note to append to an extract."
            return
        }
        do {
            // W23.h2: `append` is one atomic transaction and hands back the extract exactly as
            // written, so the index row reflects what landed (no second read to race with).
            let tx = try await ExtractBuilder(store: noteStore).append(toExtract: id,
                                                                       passages: passages)
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)])
            }
            await reloadItems()
            rebuild()
            // W14.4(b): surface the appended-to extract in the Extracts window (select + raise-if-open),
            // mirroring create — confirms the segment landed without hunting the list.
            openItem(id: id, block: nil)
        } catch { report(error, "append to the extract") }
    }

    /// The extracts currently in the store (id + display title), for the "Append to Extract…" chooser.
    /// Sorted by localized title for a stable menu; empty titles render as "Untitled".
    var existingExtracts: [(id: UUID, title: String)] {
        allItems.filter { $0.kind == .extract }
            .map { (id: $0.id, title: $0.title.isEmpty ? "Untitled" : $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    // MARK: Metadata edits (W6-S7 — dates & quality, §16.1)
    //
    // Front-matter is authoritative (00-overview D2/D9): a note's subjects, date, and quality live in its own `.md`
    // YAML (no Finder-tag mirroring since W49.storage-finder-drop-mirror). Each edit atomically writes the
    // front-matter, re-indexes that one row, and refreshes shared `allItems` so both windows' lists + the detail
    // header update live.

    @discardableResult
    func setTitle(_ title: String, to id: UUID) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return await mutateItem(id, "rename the note") { $0.title = title }
    }

    @discardableResult
    func renameNote(_ id: UUID, to title: String) async -> Bool {
        await setTitle(title, to: id)
    }

    @discardableResult
    func setTags(_ tags: [String], to id: UUID) async -> Bool {
        let tags = NotesTagVocabulary.normalizedSubjects(tags)
        return await mutateItem(id, "set the note's tags") { $0.tags = tags }
    }

    /// UI operations are deltas, so two windows adding/removing different tags cannot erase each other.
    @discardableResult
    func addTag(_ tag: String, to id: UUID) async -> Bool {
        guard let tag = NotesTagVocabulary.normalizedSubjects([tag]).first else { return false }
        return await mutateItem(id, "add the note's tag") {
            $0.tags = NotesTagVocabulary.normalizedSubjects($0.tags + [tag])
        }
    }

    @discardableResult
    func removeTag(_ tag: String, from id: UUID) async -> Bool {
        guard let token = NotesTagVocabulary.normalizedSubjects([tag]).first else { return false }
        return await mutateItem(id, "remove the note's tag") {
            $0.tags = NotesTagVocabulary.normalizedSubjects($0.tags).filter { $0 != token }
        }
    }

    /// Rewrites `id`'s subjects with `transform` in one atomic transaction on its latest front matter; for a rename or
    /// merge across notes (`NotesModel+TagRename`). `transform` sees the subjects as they are on disk and must be pure;
    /// a note it leaves as it was is not rewritten.
    func rewriteSubjects(of id: UUID, _ action: String,
                         _ transform: @escaping @Sendable ([String]) -> [String])
        async -> (before: [String], after: [String], mirrored: Bool)? {
        guard let noteStore else { return nil }
        let tx: ItemTransaction
        let seen = SubjectsSeen()
        do {
            let current = try await noteStore.load(id)
            if NotesTagVocabulary.normalizedSubjects(transform(current.tags)) == current.tags {
                return (current.tags, current.tags, true)
            }
            tx = try await noteStore.withItem(id) { item in
                seen.value = item.tags
                item.tags = NotesTagVocabulary.normalizedSubjects(transform(item.tags))
                item.modified = Date()
            }
        } catch {
            report(error, action)
            return nil
        }
        do {
            if let index { try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)]) }
        } catch { report(error, action) }
        return (seen.value, tx.item.tags, true)
    }

    /// What `rewriteSubjects`' transaction saw; written once, inside it, and read after it returns.
    private final class SubjectsSeen: @unchecked Sendable {
        var value: [String] = []
    }

    /// Set the item's date + precision (a `nil`/blank date clears the date entirely). The pair is
    /// normalized (`Item.normalizedDate`) so the stored string always matches its precision, keeping
    /// `sortDate` correct — decade → `decade * 10_000`; an uncertain date still sorts by its value
    /// (rendered italic), never dumped last.
    /// Returns whether it was saved, so the list's Date cell can put the old date back when it was not.
    @discardableResult
    func setDate(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async -> Bool {
        let n = Item.normalizedDate(date, precision: precision)
        return await mutateItem(id, "set the date") { item in
            item.date = n.date
            item.datePrecision = n.precision
        }
    }

    /// Toggle the "date uncertain" flag (the date renders italic but still sorts by its value).
    func setDateUncertain(_ uncertain: Bool, for id: UUID) async {
        await mutateItem(id, "set date uncertainty") { $0.dateUncertain = uncertain }
    }

    /// Choose the calendar `id`'s dates are SHOWN in (W24.cal1-toggle). Display only: `date` and
    /// `sentWith` are not touched, so the stored ISO values are the same bytes before and after.
    /// `standard` (or nil) clears the choice and writes no key; any `display_calendar` value this build
    /// could not read is retired, since an explicit choice settles it.
    @discardableResult
    func setDisplayCalendar(_ calendar: DisplayCalendar?, for id: UUID) async -> Bool {
        await mutateItem(id, "set the display calendar") { item in
            item.displayCalendar = calendar == .standard ? nil : calendar
            item.unknownFrontMatter.removeAll { $0.key == FrontMatterCodec.displayCalendarKey }
        }
    }

    /// Set the covering letter's ("sent with") date — W37.dual-date. The same normalization as the own
    /// date (`Item.normalizedDate`), then the Core whole value; a `nil`/blank date clears it together
    /// with its uncertainty flag. A value Core cannot carry (a year outside 3–4 digits) is refused with
    /// a status message rather than written or silently clearing the existing date. Projection mirrors
    /// it as `Sent With …` through the same exact-ownership facet path as the own date.
    @discardableResult
    func setSentWith(_ date: String?, precision: Item.DatePrecision?, for id: UUID) async -> Bool {
        let n = Item.normalizedDate(date, precision: precision)
        // An explicit edit of the role settles it: any other kept `sent_with` entry (or an unreadable
        // inline value) is retired, so a cleared date can never be replaced by it on the next load.
        @Sendable func retireStale(_ item: inout Item) {
            item.unparsedAdditionalDates.removeAll {
                $0.key == FrontMatterCodec.sentWithAdditionalDateKey || $0.key == FrontMatterCodec.inlineAdditionalDatesKey
            }
        }
        guard n.date != nil else {
            return await mutateItem(id, "clear the sent-with date") { item in
                item.sentWith = nil
                item.sentWithUncertain = false
                retireStale(&item)
            }
        }
        guard let value = Item.archiveDate(n.date, precision: n.precision) else {
            statusMessage = "A sent-with date needs a 3- or 4-digit year."
            return false
        }
        return await mutateItem(id, "set the sent-with date") { item in
            item.sentWith = value
            retireStale(&item)
        }
    }

    /// Toggle the sent-with date's own uncertainty flag (independent of the own date's). A no-op
    /// without a sent-with date, so the flag can never be stored on its own.
    func setSentWithUncertain(_ uncertain: Bool, for id: UUID) async {
        await mutateItem(id, "set sent-with date uncertainty") { item in
            item.sentWithUncertain = item.sentWith != nil && uncertain
        }
    }

    /// Round-up is ordinary-note metadata, persisted through the same fresh-load transaction as the other fields.
    @discardableResult
    func setRoundup(_ roundup: Bool, for id: UUID) async -> Bool {
        guard let noteStore else { return false }
        do {
            guard try await noteStore.load(id).kind == .note else { return false }
            return await mutateItem(id, "set round-up status") { $0.roundup = roundup }
        } catch { report(error, "set round-up status"); return false }
    }

    /// Set the quality rating on the canonical 0...3 scale. `nil`, 0, and invalid inputs are unrated
    /// (no quality key in front-matter). A valid 1...3 value is stored in front-matter YAML only
    /// (no Finder-tag mirroring since W49.storage-finder-drop-mirror). The archive corpus is never touched.
    func setQuality(_ quality: Int?, for id: UUID) async {
        guard let noteStore else { return }
        let canonical = quality.flatMap { (1...3).contains($0) ? $0 : nil }
        do {
            let tx = try await noteStore.withItem(id) { item in
                item.quality = canonical
                item.modified = Date()
            }
            if let index {
                try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)])
            }
            await reloadItems()
        } catch { report(error, "set the quality") }
    }

    // MARK: Note body load / save (W7-S1a — the editor↔item wiring that gates W7 Extracts)
    //
    // The detail-pane editor edits the note's FULL body markdown: the leading prose plus the serialized
    // `<!-- block: -->` source-block headers (00-overview §5/§6). Load serializes the stored
    // `(trailingBodyRaw, blocks)` back to that markdown; save parses it and writes through the SAME
    // audited `mutateItem` path the date/quality editors use (load-fresh → atomic `.md` save → one-row
    // re-index → publish). Body text is Notes' OWN store only — never a Finder tag, never the archival
    // corpus (Prime Directive #1). `setBody` bumps `modified` (via `mutateItem`) since it is a real edit.

    /// Serialize the item's stored body to the editor's full-body markdown, or nil if it can't be read
    /// (missing/unreadable note — the caller then leaves the editor empty rather than showing a stale
    /// buffer). Read-only: does not touch the store.
    func loadBody(for id: UUID) async -> String? {
        guard let noteStore else { return nil }
        do {
            let item = try await noteStore.load(id)
            return BlockParser.serialize(leadingText: item.trailingBodyRaw, blocks: item.blocks)
        } catch { report(error, "load the note body"); return nil }
    }

    /// The saved body's word and character count for the inspector (W49.notes-polish-small). Quiet: a note that
    /// cannot be read shows no count rather than an error over the window.
    func loadTextCounts(for id: UUID) async -> NoteTextStats.Counts? {
        guard let noteStore, let item = try? await noteStore.load(id) else { return nil }
        return NoteTextStats.counts(markdown: BlockParser.serialize(leadingText: item.trailingBodyRaw,
                                                                    blocks: item.blocks))
    }

    /// The items File ▸ Export… and Print… read, in `ids` order (W49.notes-export-print). Read-only: each is loaded
    /// fresh from its `.md`, with its folder (the base of its `assets/` references) and the list's date text. An
    /// item that cannot be read is left out and named in `failed`.
    func exportSources(for ids: [UUID]) async -> (sources: [NoteExportSource], failed: [String]) {
        guard let noteStore else { return ([], []) }
        let root = noteStore.rootURL
        var sources: [NoteExportSource] = []
        var failed: [String] = []
        let wanted = Set(ids)
        let summaries = Dictionary(allItems.lazy.filter { wanted.contains($0.id) }.map { ($0.id, $0) },
                                   uniquingKeysWith: { first, _ in first })
        for id in ids {
            let summary = summaries[id]
            do {
                let item = try await noteStore.load(id)
                sources.append(NoteExportSource(item: item, itemDirectory: NoteStore.itemDir(root: root, id: id),
                                                dateText: summary?.dateColumnText))
            } catch {
                failed.append(summary?.title ?? id.uuidString)
            }
        }
        return (sources, failed)
    }

    /// The open library's folder, which Export never writes into.
    var storeRootURL: URL? { noteStore?.rootURL }

    /// Read-only extract provenance for the detail inspector. Loading the stored blocks preserves
    /// their saved source labels and never touches a source note or the archive corpus.
    func loadExtractSources(for id: UUID) async -> [ExtractSourceUsage]? {
        guard let noteStore else { return nil }
        do {
            let item = try await noteStore.load(id)
            return item.kind == .extract ? item.blocks.notePassageSourceUsage : []
        } catch { report(error, "read extract sources"); return nil }
    }

    /// Every Reader link in a note's source blocks, for what produced their collections (W46.settings-reader-notes).
    /// A block without a link is skipped.
    func loadReaderSourceLinks(for id: UUID) async -> [String] {
        guard let noteStore else { return [] }
        do {
            let item = try await noteStore.load(id)
            guard item.kind == .note else { return [] }
            return item.blocks.filter { $0.kind == .readerDoc || $0.kind == .readerPage }.compactMap { $0.source?.link }
        } catch { report(error, "read source links"); return [] }
    }

    /// Read every Reader source from the current round-up body. A malformed/missing source must not
    /// be skipped when deciding whether ALL linked PDFs share a year.
    func loadRoundupSourceLinks(for id: UUID) async -> [String]? {
        guard let noteStore else { return nil }
        do {
            let item = try await noteStore.load(id)
            guard item.kind == .note, item.roundup else { return nil }
            let sources = item.blocks.filter { $0.kind == .readerDoc || $0.kind == .readerPage }
            guard !sources.isEmpty else { return nil }
            var links: [String] = []
            for source in sources {
                guard let link = source.source?.link else { return nil }
                links.append(link)
            }
            return links
        } catch { report(error, "read round-up sources"); return nil }
    }

    /// Parse edited body markdown back into `(leadingText, blocks)` and persist it atomically through
    /// `mutateItem`, so it shares the date/quality write path's guarantees (fresh load → atomic save →
    /// single-row re-index → publish). A failed write surfaces via `statusMessage` and leaves the
    /// on-disk `.md` untouched (the disk is the source of truth). A no-op with no `noteStore`.
    func setBody(_ markdown: String, for id: UUID) async {
        let parsed = BlockParser.parse(markdown)
        await mutateItem(id, "save the note") { item in
            item.trailingBodyRaw = parsed.leadingText
            item.blocks = parsed.blocks
        }
    }

    /// Editor-only optimistic save. The per-pane baseline is explicit, never shared by UUID. Once a
    /// conflict draft is on disk, return the original's latest body so the pane can safely reload it.
    /// A failed content/recovery write returns nil; the editor must retain its dirty buffer.
    func saveEditorBody(_ markdown: String, basedOn expectedBody: String, for id: UUID) async -> String? {
        guard let noteStore else { return nil }
        do {
            let saved = try await noteStore.saveBody(markdown, basedOn: expectedBody, for: id)
            var transactions = [saved.current]
            if let recovery = saved.recoveredDraft {
                transactions.append(recovery)
                do {
                    let folder = recovery.item.kind == .extract ? organization.extractsHomeFolderId
                        : OrganizationStore.inboxFolderId
                    try await organization.addMembership(item: recovery.item.id, folder: folder)
                } catch { report(error, "file the recovered draft (it is saved in the store)") }
            }
            // Cache/projection failures cannot turn a successful content save into a failed one:
            // retrying an old baseline after that would manufacture another conflict draft.
            for tx in transactions {
                do {
                    if let index { try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)]) }
                } catch { report(error, "index the saved note") }
            }
            await reloadItems()
            rebuild()
            if let recovery = saved.recoveredDraft {
                statusMessage = "This note changed outside this editor. Your in-app version was saved as \"\(recovery.item.title)\"; the original was reloaded."
            }
            return saved.body
        } catch { report(error, "save the note; keep this editor open and retry"); return nil }
    }

    /// W7-S5 — an item-scoped inline-image asset store over the audited `NoteStore`, or nil before
    /// bootstrap / for an injected (store-less) test model. The editor pane creates one and retargets it
    /// to the selected item so pasted/dropped images persist into that item's `assets/`.
    func makeAssetStore() -> ItemAssetStore? {
        guard let noteStore else { return nil }
        let assets = ItemAssetStore(store: noteStore, root: noteStore.rootURL)
        assets.onWriteFailure = { [weak self] name, itemID, _ in
            self?.reportAssetWriteFailure(name: name, itemID: itemID)
        }
        return assets
    }

    /// A pasted or dropped image whose bytes could not be written (W40.fix-notes-asset-write-silent).
    /// The note keeps its `assets/<name>` reference, drawn as the "Missing" placeholder, so the user can
    /// see which image to paste again. The line names the note, since the write lands after the paste
    /// and the user may have moved to another one by then.
    func reportAssetWriteFailure(name: String, itemID: UUID) {
        let title = allItems.first(where: { $0.id == itemID })?.title ?? ""
        let inNote = title.isEmpty ? "" : " in “\(title)”"
        statusMessage = "Couldn't store the pasted image \(name)\(inNote). It shows as Missing; paste it again."
    }

    // MARK: Zotero references & auto-fill

    /// Attach a canonical note-level reference without replacing a concurrent body or metadata edit.
    /// Reattaching the same link preserves its existing citation and fetch timestamp.
    @discardableResult
    func attachZoteroReference(_ ref: ZoteroRef, to id: UUID) async -> Bool {
        guard let canonical = ZoteroSelectLink.parse(ref.selectLink) else { return false }
        return await mutateItem(id, "attach the Zotero reference") { item in
            guard !item.zotero.contains(where: { $0.selectLink == canonical.selectLink }) else { return }
            item.zotero.append(canonical)
        }
    }

    /// A late citation response must neither resurrect a removed link nor overwrite a newer citation.
    @discardableResult
    func cacheZoteroCitation(_ citation: String, for ref: ZoteroRef, in id: UUID) async -> Bool {
        await mutateItem(id, "save the Zotero citation") { item in
            guard let position = item.zotero.firstIndex(where: { $0.selectLink == ref.selectLink }),
                  item.zotero[position].citation == ref.citation,
                  item.zotero[position].fetchedAt == ref.fetchedAt else { return }
            item.zotero[position].citation = citation
            item.zotero[position].fetchedAt = Date()
        }
    }

    /// Read the current item for Zotero inspectors and auto-fill. This is intentionally a
    /// read only; the sheet's eventual confirm goes through `applyZoteroAutoFill`, which re-reads inside
    /// `withItem` rather than saving this snapshot back wholesale.
    func itemForZoteroAutoFill(_ id: UUID) async -> Item? {
        guard let noteStore else { return nil }
        do { return try await noteStore.load(id) }
        catch { report(error, "read the note for Zotero auto-fill"); return nil }
    }

    /// Commit just the fields the Zotero confirmation selected, plus its one refreshed Zotero reference.
    /// `resolved` is based on a snapshot taken before the sheet opened, so assigning it as a whole would
    /// reintroduce W23.h2's lost-update bug by discarding a body/edit that arrived while the sheet was open.
    /// This transaction instead applies the derived field deltas to the current on-disk item.
    func applyZoteroAutoFill(_ resolved: Item, basedOn base: Item,
                             target: ZoteroAutoFillReferenceTarget) async throws {
        guard let noteStore else { throw ZoteroAutoFillSaveError.storeUnavailable }
        guard resolved.id == base.id else { throw ZoteroAutoFillSaveError.itemMismatch }

        let applyTitle = resolved.title != base.title
        let applyDate = resolved.date != base.date || resolved.datePrecision != base.datePrecision
        let refreshedRef = target.noteFrontMatter
            ? resolved.zotero.first(where: { $0.selectLink == target.selectLink })
            : nil
        let baseRef = base.zotero.first(where: { $0.selectLink == target.selectLink })
        if target.noteFrontMatter, refreshedRef == nil { throw ZoteroAutoFillSaveError.referenceMissing }
        let baseBlockDisplays = base.blocks.compactMap { block -> String? in
            guard block.source?.zoteroSelect == target.selectLink else { return nil }
            return block.source?.display
        }
        let resolvedBlockDisplays = resolved.blocks.compactMap { block -> String? in
            guard block.source?.zoteroSelect == target.selectLink else { return nil }
            return block.source?.display
        }
        let applySourceCitation = target.sourceBlocks && resolvedBlockDisplays != baseBlockDisplays

        let tx = try await noteStore.withItem(base.id) { item in
            if target.noteFrontMatter,
               !item.zotero.contains(where: { $0.selectLink == target.selectLink }) {
                throw ZoteroAutoFillSaveError.referenceRemoved
            }
            if target.sourceBlocks,
               !item.blocks.contains(where: { $0.source?.zoteroSelect == target.selectLink }) {
                throw ZoteroAutoFillSaveError.referenceRemoved
            }
            if applyTitle { item.title = resolved.title }
            if applyDate {
                item.date = resolved.date
                item.datePrecision = resolved.datePrecision
            }
            if let refreshedRef {
                item.zotero = item.zotero.map { existing in
                    guard existing.selectLink == target.selectLink,
                          existing.citation == baseRef?.citation,
                          existing.fetchedAt == baseRef?.fetchedAt else { return existing }
                    var updated = existing
                    // Compare against the snapshot before assigning: an inspector fetch may have saved a
                    // newer citation while this sheet was open, including when this fetch failed (nil).
                    updated.citation = refreshedRef.citation
                    updated.fetchedAt = refreshedRef.fetchedAt
                    return updated
                }
            }
            if applySourceCitation {
                let display = resolvedBlockDisplays.first
                item.blocks = item.blocks.map { existing in
                    guard existing.source?.zoteroSelect == target.selectLink else { return existing }
                    var updated = existing
                    updated.source?.display = display
                    return updated
                }
            }
            item.modified = Date()
        }
        if let index {
            try await index.upsertBatch([NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)])
        }
        await reloadItems()
    }

    enum ZoteroAutoFillSaveError: LocalizedError {
        case storeUnavailable, itemMismatch, referenceMissing, referenceRemoved

        var errorDescription: String? {
            switch self {
            case .storeUnavailable: "The Notes store is not available."
            case .itemMismatch: "The selected note changed before auto-fill could be applied."
            case .referenceMissing: "The selected Zotero reference is no longer available."
            case .referenceRemoved: "That Zotero reference was removed while the confirmation was open."
            }
        }
    }

    /// Shared atomic-transaction → single-row re-index → publish path for the field editors above. A
    /// no-op with no `noteStore` (an injected test model built without one). The on-disk `.md` is the
    /// source of truth and the index is a rebuilt-from-disk projection, so nothing here can corrupt
    /// data; errors surface via `statusMessage` like the other mutations.
    ///
    /// **W23.h2 — the whole load→mutate→save runs inside ONE `NoteStore.withItem` call.** Spelling it
    /// out here as separate `load` / `save` awaits made it a lost-update race: `NotesModel` is
    /// `@MainActor` but *reentrant at every `await`*, so a body autosave and a metadata edit could both
    /// load the same old item and the later save would silently drop the other's field. `mutate` must
    /// therefore stay synchronous — that is what makes the transaction atomic.
    @discardableResult
    private func mutateItem(_ id: UUID, _ action: String,
                            _ mutate: @Sendable (inout Item) -> Void) async -> Bool {
        guard let noteStore else { return false }
        do {
            let tx = try await noteStore.withItem(id) { item in
                mutate(&item)
                item.modified = Date()
            }
            if let index {
                let row = NoteIndexRow(item: tx.item, mtime: tx.ref.mtime)
                #if DEBUG
                if let indexProjectionTestHook { await indexProjectionTestHook(row) }
                #endif
                try await index.upsertBatch([row])
            }
            await reloadItems()
            return true
        } catch { report(error, action); return false }
    }
}
