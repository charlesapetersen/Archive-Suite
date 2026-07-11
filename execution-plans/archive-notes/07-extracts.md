# Archive Notes — W7: Extracts (snapshot + provenance, blocks→notes, jump-to-source)
> Status: PROPOSED · part of Archive Notes (see 00-overview.md) · Wave 7

> ⚠️ **Canonical shared types & cross-wave APIs are defined in `00-overview.md` §16 (Interface Contract).** Where a sketch in this file differs — store type/name (`actor NoteStore` + `@MainActor NotesModel`/`OrganizationStore`), `DurableLink`/`RootMarker`, the single `NotesFilter` type, template-assignments-only, the index `items` projection, the `archivenotes://open?id=` grammar — **the overview is authoritative.**


## Goal
Add the **extract** experience on top of the unified `Item` model: a user reading/writing a note can select a passage and, with one command, mint a *new, independently-editable* `Item(kind: .extract)` that holds a **snapshot copy** of that rich text plus a durable **note-passage** provenance link back to the source note+block (`archivenotes://open?id=…#block-n`, per 00-overview §8.2). Extracts can be **segmented** — appended with blocks that link to *different* source notes — each block carries a **jump-to-source** control and a provenance chip (source-note title/date), and the Extract window *features* extracts (kind filter defaults to `.extracts`) while the Note window features notes, both toggleable via the shared `notes|extracts|both` control (00-overview §D7, §3.1–3.3, §7). Editing a source note **never** mutates a derived extract (snapshot semantics, D7).

## Dependencies
Must land first (all net-new; none exist in the repo today):
- **W1/`01`** — `ArchiveNotes/` scaffold + `ArchiveCore` package (provides `DocumentTags.sortDate`/`displayDate` reused for extract date rendering, 00-overview §7, §10).
- **W2/`02`** — the `Item`/`Block`/`SourceAnchor` types, the front-matter reader/writer, the `NoteStore` atomic item creator + **asset-copy helper**, `organization.json` membership rows, and the FTS index. W7 *calls* these writers and adds **no new file-writing choke-point** (this is what keeps W7 Tier-1 — see §Risks). W2 must expose the `note-passage` `SourceKind` case (00-overview §3.2) and a `NoteStore` API to create an item from an in-memory `(Item, [Block])` and to copy named assets into a new item's `assets/`.
- **W3/`03`** — the rich-text editor: `NoteEditorModel` + the `NSTextView`/TextKit host, the **attributed⇄Markdown bridge**, the per-block render map, and the editor's **copy/paste handler** (W7 contributes one pasteboard representation + one paste branch to it).
- **W4/`04`** — the `archivenotes://` scheme: the app-level URL **router** + `.onOpenURL`, and the in-process `NotesNavigation.openItem(id:block:)` resolve path (00-overview §8.2–§8.3). W7's jump-to-source and back-link chip call this; W7 does **not** redefine the scheme.
- **W6/`06`** — the shared 3-pane `ViewerModel` and the two windows (Note viewer, Extract viewer), the item list, and the folder sidebar. W6 introduces the `KindFilter` control; W7 sets the per-window default and wires the segmented control (if W6 has not already added `KindFilter`, W7 adds it to the shared model — see S4).

## Design

### 1. Data model (extends W2 types; nothing here re-decides 00-overview)
Extracts reuse the **exact** front-matter + block model of notes (00-overview §5, §3.1), with `kind: extract` and blocks whose only *sourced* kind is `note-passage`. **Invariant (owner, §D7): an extract references NOTES only** — a `reader-page`/`reader-doc`/`zotero-*` anchor must never appear in an extract; the paste/create paths coerce any such anchor to `freeform` (see §5, and the `test_extractRejectsNonNoteAnchors` test).

**`SourceKind.notePassage`** (W2 defines the enum; W7 confirms this case + serialization):
```swift
// note-passage source header on disk (00-overview §6, §8.2 canonical link form):
// <!-- block: note-passage
//      note: archivenotes://open?id=7F3A9C21-…#block-2
//      display: "Moore on Intel culture — 1968" -->
```
> **Reconciliation note (do not re-decide):** 00-overview §6's grammar sketch shows `note: <archivenotes://note/uuid#anchor>` while §8.2 locks the canonical form `archivenotes://open?id=<UUID>#block-<n>`. W7 uses the **§8.2 canonical form** (the mandate specifies it). Flag to W4 (scheme owner) to make §6's example match; W7's parser also tolerates the older `note/uuid#anchor` spelling read-only for forward safety.

**Note-passage helpers** — NEW, `Core/SourceAnchor+NotePassage.swift` (pure, `Sendable`, unit-testable off-actor):
```swift
extension SourceAnchor {
    /// Factory for an extract's provenance anchor. `link` is the durable §8.2 URL; `display` is the
    /// snapshot label (source title + rendered date) shown in the provenance chip.
    static func notePassage(sourceNoteId: UUID, sourceBlockIndex: Int,
                            sourceTitle: String, sourceDateDisplay: String) -> SourceAnchor {
        SourceAnchor(type: .notePassage,
                     link: "archivenotes://open?id=\(sourceNoteId.uuidString)#block-\(sourceBlockIndex)",
                     display: "\(sourceTitle) — \(sourceDateDisplay)")
    }
    /// Parse the target out of a note-passage `link` (nil for non-passage anchors / malformed URLs).
    /// Tolerates both `open?id=UUID#block-N` (§8.2) and legacy `note/UUID#block-N` (§6).
    var notePassageTarget: (id: UUID, block: Int?)? { /* URLComponents parse; regex #block-(\d+) */ }
}
```
Block index `n` is the **ordinal** of the source block in the source note at snapshot time (per §8.2). This is intentionally lightweight and *best-effort* on jump (§3). *Open question §OQ1* proposes a stable block GUID; W7 ships ordinals to match the locked spec and **degrades gracefully** when the source note has since changed.

**On-disk example — an extract** (`<store>/items/<uuid>/…md`), showing two segments linking to two different notes:
```markdown
---
schema: 1
id: c4e11a90-1f77-4a2b-9d0e-2b6f3a5c8e10
kind: extract
title: Egalitarian culture — Moore vs. Noyce
authors: []
date: 2026-07-10
date_precision: day
date_uncertain: false
tags: []
created: 2026-07-10T21:30:00Z
modified: 2026-07-10T21:30:00Z
---

<!-- block: note-passage
     note: archivenotes://open?id=7F3A9C21-4B2E-4D1A-9C33-8E5F0A1B2C3D#block-2
     display: "Moore on Intel culture — 1968" -->
Moore says he and Noyce were **responsible** for Intel's early egalitarian culture…

<!-- block: note-passage
     note: archivenotes://open?id=B1D4E0F7-…#block-0
     display: "Noyce resigns from Fairchild — 1968" -->
Noyce, by his own account, set the tone the day he walked out of Fairchild…
```

### 2. `ExtractBuilder` — the snapshot service (NEW, `Core/ExtractBuilder.swift`)
The single place that turns a live editor selection (or a pasted payload) into extract `Block`s + a new `Item`. Selection reading touches `NSTextView`, so the builder is `@MainActor`; persistence hands `Sendable` value types to the async `NoteStore`.
```swift
@MainActor
struct ExtractBuilder {
    let store: NoteStore            // W2 (async actor)
    let now: () -> Date = Date.init // injectable for deterministic tests

    /// Snapshot the current selection in `editor` into one Block per covered source block (§Algorithm).
    /// Pure w.r.t. the source note — reads only; copies image bytes.
    func passageBlocks(fromSelectionIn editor: NoteEditorModel) -> [Block]

    /// Create a brand-new extract from the selection and persist it (new UUID folder + assets),
    /// then add a membership row to `folderId` (Extracts home if nil). Returns the created Item.
    func createExtract(fromSelectionIn editor: NoteEditorModel, into folderId: UUID?) async throws -> Item

    /// Segmentation: append the selection's blocks to an EXISTING extract (which may already link to
    /// other notes) and re-save. Cross-note segmentation lives here (owner requirement, §D7).
    func append(toExtract id: UUID, fromSelectionIn editor: NoteEditorModel) async throws

    /// Build blocks from a pasted Notes-passage payload (copy-from-Notes → paste-into-Extract, §5).
    func passageBlocks(from payload: NotesPassagePayload) -> [Block]
}
```

**Algorithm — `passageBlocks(fromSelectionIn:)`:**
1. Read `editor.textView.selectedRange()` (NSRange, UTF-16). If length 0 → return `[]` (caller shows *"Select text in the note to make an extract."*). Handle multiple discontiguous selections via `selectedRanges` (rare; treat each range like a selection and concatenate the resulting blocks in document order).
2. Using W3's per-block render map `editor.model.blockRanges: [(blockIndex: Int, range: NSRange)]` (the character span each block occupies in the rendered text), compute the set of source blocks the selection **intersects** and, for each, the **sub-range** of that block's text covered.
3. For each covered source block `b` (ascending order):
   - `attr = textView.textStorage.attributedSubstring(from: coveredSubRange)` — the **snapshot** (a value copy; the source note is never mutated).
   - `md = MarkdownBridge.attributedToMarkdown(attr)` (W3 bridge).
   - Collect inline-image asset filenames referenced by `attr`; snapshot their **bytes** (independent copy — not a reference — for durable snapshot semantics).
   - Build the anchor **regardless of the source block's own kind** — even a `freeform` source block yields a `note-passage` anchor to `(sourceNoteId, b)`, because provenance is "this passage came from note X, block b":
     `SourceAnchor.notePassage(sourceNoteId: editor.item.id, sourceBlockIndex: b, sourceTitle: editor.item.title, sourceDateDisplay: DocumentTags.displayDate(editor.item.dateFacet))`.
   - `Block(source: anchor, markdown: md, pendingAssets: [name: Data])`.
4. Return the ordered `[Block]`.

**`createExtract`:** build blocks → assemble `Item`:
- `id = UUID()`, `kind = .extract`, `title = Self.defaultTitle(fromFirstLineOf: blocks)`, `authors = []`, `date = now()` + `date_precision = .day` + `date_uncertain = false` (extract owns its **own** date — D7; default = creation day, user can edit in W6's date control), `quality = nil`, `tags = []`, `sources` = union of block anchors, `created = modified = now()`, `schema = 1`.
- Persist: `let created = try await store.createItem(item, blocks: blocks)` — W2 writes the UUID folder + `.md`, copies each block's `pendingAssets` into `<uuid>/assets/` (via W2's audited copy helper), rewrites the markdown image paths, and runs `NotesTagProjector` for the (empty) subjects + `ArchiveSuite`.
- Membership: `try await store.addMembership(itemId: created.id, folderId: folderId ?? store.extractsHomeFolderId)` (W2/W6 organization graph; a new extract lands in the Extracts window's current folder or the Extracts "Inbox").

**`defaultTitle(fromFirstLineOf:)`** (NEW, pure, tested): first non-empty line of the combined snapshot markdown, stripped of Markdown markers (`#`, `*`, `_`, `>`, list bullets), whitespace-trimmed, truncated to 80 chars on a word boundary; fallback `"Extract " + shortDate(now())` when the snapshot is whitespace/image-only.

**Segmentation (`append`):** load the existing extract `(item, blocks)` via `store.loadItem(id)`, append the new passage blocks, bump `modified`, `try await store.saveItem(item, blocks: existing + new)`. The appended blocks may link to a *different* note than the existing ones — this is the owner's segmentation requirement and needs no special case beyond "an extract is a list of note-passage blocks."

### 3. Jump-to-source & provenance display (NEW, `Views/ExtractBlockHeaderView.swift`)
Each extract block renders a **provenance header** above its body (only when the block has a `note-passage` anchor):
- A **back-link chip**: `"↩ <live-or-snapshot source title> · <date>"`. Resolve the *live* title/date by `anchor.notePassageTarget?.id` through `store.metadata(for: id)` (async, cached) so a renamed source note shows its **current** title; fall back to the snapshot `display` string when the id is unresolvable (deleted note). Rendered as a tappable capsule (SwiftUI `Label` in a `Capsule` background), matching the token-chip visual language.
- A **"Jump to source"** button (SF Symbol `arrow.up.forward.square`) → `onJump(anchor)`.

`onJump` calls the in-process resolve (same-app navigation, no OS URL round-trip):
```swift
guard let (id, block) = anchor.notePassageTarget else { return }
NotesNavigation.openItem(id: id, block: block)   // W4: reveals the note in the Note window
```
`NotesNavigation.openItem(id:block:)` (W4) locates the item, ensures/raises the **Note** window, selects the item, and requests a scroll to `block`. The scroll-into-view uses the **coalescing counter pattern reused verbatim from `NavigationModel`** (`scrollRequest`/`scrollTargetID`/`requestScroll(to:)`, `NavigationModel.swift:65-67, 672`): a `@Published private(set) var scrollBlockRequest` bumped `&+= 1` with `scrollTargetBlock` set, so scrolling to the *same* block twice still fires. The Note editor view observes the counter and calls `NSTextView.scrollRangeToVisible(editor.model.blockRanges[block].range)` (net-new; the Reader's PDF analog is `PDFPaneView.go(to:)`, `PDFPaneView.swift:77,80`).

**Graceful degradation (best-effort ordinal anchor):**
- Source note **deleted** → chip shows snapshot title greyed with a "source removed" tooltip; jump shows a non-modal status *"The source note for this passage no longer exists — the extract text is preserved."* (the snapshot text is intact; nothing is lost).
- Source note exists but block `n` is **out of range** (source edited since snapshot) → open + select the note, scroll to top, status *"The source note has changed since this extract was made."*
- URL resolves to a `kind != .note` item (defensive) → treat as unresolvable.

### 4. Extract-viewer featuring (S4)
`KindFilter` (W6 owns; W7 adds if absent) drives which items the shared list shows:
```swift
enum KindFilter: String, CaseIterable, Sendable { case notes, extracts, both }
```
- **Note window** default `.notes`; **Extract window** default `.extracts`. The default is set when each window's `ViewerModel` is constructed (W6 scene wiring); persisted per-window in `UserDefaults` (`an.noteWindow.kindFilter` / `an.extractWindow.kindFilter`) reusing W6's view-state persistence.
- A **segmented control** (`Picker(.segmented)` bound to `viewerModel.kindFilter`) in each window's toolbar lets either window show `notes | extracts | both`. Selecting `.both` unions; the list column set adapts (extracts show a "Sources" count column = number of distinct linked notes; notes show their normal columns).
- The list query is a DB predicate on the FTS/organization tables (W2): `WHERE kind IN (…)` — no in-memory scan (scales at 100k, 00-overview §11).
- Featuring differences beyond the filter: the **Note** window's Selection menu exposes **Create Extract** (§6); the **Extract** window's editor renders the `ExtractBlockHeaderView` provenance affordances (§3) and its inspector shows a provenance summary (the list of distinct source notes with counts).

### 5. Round-trip with the Notes UI (copy-from-Notes → paste-into-Extract) + plain paste
Two ways to make an extract, both producing identical `note-passage` blocks:
- **(a) Create Extract command** (selection-based, §6/§2) — mints a new extract.
- **(b) Copy in a note, paste into an extract** — appends to the open extract.

To make (b) carry provenance, W7 contributes **one pasteboard representation** to W3's editor copy handler and **one paste branch** to the extract editor:
```swift
// Custom UTI (declared in ArchiveNotes Info.plist, UTExportedTypeDeclarations) — analogous to
// Reader's Copy-Archive-Link custom-UTI JSON payload (00-overview §8.4 / W4).
static let notesPassageUTI = "com.archivenotes.passage"

struct NotesPassagePayload: Codable, Sendable {
    var sourceNoteId: UUID
    var sourceTitle: String
    var sourceDateDisplay: String
    var segments: [Segment]
    struct Segment: Codable, Sendable {
        var sourceBlockIndex: Int
        var markdown: String
        var assetPNGs: [String: Data]   // inline-image filename → PNG bytes (snapshot)
    }
}
```
- **Copy in the note editor** (W3 copy path, W7 addition): when the selection lies inside a *note*, write a **multi-representation** pasteboard item — plain `NSString` (fallback for external apps like Scrivener), system RTF (from `attributedSubstring`), **plus** the `com.archivenotes.passage` JSON built by `ExtractBuilder.passageBlocks(...)` mapped to `NotesPassagePayload`. Reuses the pasteboard idiom in `NavigationModel.copyLinks()` (`NavigationModel.swift:874-881` — `clearContents()` + typed `setData`/`setString`).
- **Paste into an extract editor**: if the pasteboard carries `com.archivenotes.passage` → `ExtractBuilder.passageBlocks(from: payload)` → insert as `note-passage` block(s) at the caret (provenance preserved). Otherwise (plain text / RTF / external) → insert as a **`freeform`** block (no source) via the normal W3 paste. **Enforce the extract-references-notes-only invariant here:** a pasteboard also carrying a Reader `archivereader://` link payload (W4) is **ignored for source purposes** and degrades to freeform text with a one-line status *"Extracts link to notes only — pasted as plain text."*
- **Plain paste** therefore "just works": any non-Notes source becomes freeform text; a Notes copy becomes a provenanced passage. No mode switch for the user.

### Concurrency / Swift 6 notes
- `ExtractBuilder`, `ExtractBlockHeaderView`, the copy/paste handlers, and the two `ViewerModel`s are `@MainActor` (they touch `NSTextView`/AppKit and `@Published` UI state).
- `Item`, `Block`, `SourceAnchor`, `NotesPassagePayload` (+ its `Segment`) are `Sendable` value types crossing to the async `NoteStore` actor. Image bytes travel as `Data` (Sendable) inside the payload/blocks — no `NSImage`/`NSAttributedString` crosses an actor boundary.
- Async resolution for the live-title chip + membership uses the **generation-token coalescing** pattern from `NavigationModel.runFullTextSearch()` (`NavigationModel.swift:431-454`) so a superseded resolve can't overwrite a newer render; guard `guard generation == self.gen else { return }` after each `await`.
- `SourceAnchor+NotePassage`, `defaultTitle`, and the block-range→covered-blocks mapping are `nonisolated`/pure so they unit-test off the main actor.

## Reuse from the existing codebase
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/SubjectTokenField.swift:25-108`** — the *edit-start-base snapshot + one-delta commit-on-blur* discipline (`editBase` captured at `controlTextDidBeginEditing`, diffed at `controlTextDidEndEditing`, `commit(base, edited)`; `updateNSView` freezes while `currentEditor() != nil`, lines 52-64, 90-106). Copy this pattern for the **extract's own tag/title editing** in the Extract window so a concurrent re-render (index echo) can't clobber an in-progress edit or drop a third-party token — the extract's `tags` still route through `NotesTagProjector` as a delta, never a full overwrite (00-overview §9).
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/NavigationModel.swift:65-67, 672`** (`scrollRequest`/`scrollTargetID`/`requestScroll(to:)`) — copy verbatim as `scrollBlockRequest`/`scrollTargetBlock`/`requestScrollToBlock(_:)` to drive jump-to-source scroll-into-view (§3), so scrolling to the same block twice still fires.
- **`NavigationModel.swift:874-881`** (`copyLinks()` — `NSPasteboard.general.clearContents()` then typed writes) — adapt for the multi-representation Notes-passage copy (§5).
- **`NavigationModel.swift:431-454`** (`runFullTextSearch()` generation-token guard) — adapt for the async live-title-chip resolve and membership add.
- **`NavigationModel.swift:32, 487-490`** (`selection: Set<…>` + `refreshSelectionCache`) — the selection idiom for the Extract window list.
- **`ArchiveReader/macOS/Sources/ArchiveReader/Views/PDFPaneView.swift:77,80`** (`go(to: PDFDestination(page:at:))`) — the *analog* of scroll-to-destination; for Notes the actual call is net-new `NSTextView.scrollRangeToVisible(_:)` (PDF has no text-view scroll primitive to lift, so this is a pattern reference only).
- **`ArchiveCore.DocumentTags.sortDate` / `displayDate` / `dateIsSpeculative`** (seeded from Reader `Core/DocumentTags.swift`, 00-overview §7, §10) — reuse for rendering the extract's own date and the provenance chip date. Do **not** hand-roll date formatting.
- **Reader's Copy-Archive-Link multi-representation pasteboard** (00-overview §8.4 / W4) — mirror the "plain text + custom-UTI JSON payload" idiom for the `com.archivenotes.passage` payload.

*(All `ArchiveNotes/…` types named above — `Item`, `Block`, `SourceAnchor`, `NoteStore`, `NoteEditorModel`, `MarkdownBridge`, `NotesNavigation`, `ViewerModel`, `KindFilter` — are **net-new** in W2/W3/W4/W6 and do not exist in the repo today; W7 consumes them.)*

## Bounded sub-tasks

### S1 — Extract data model + `ExtractBuilder` snapshot core (no UI)
- **Scope:** the `note-passage` anchor helpers, `ExtractBuilder` (`passageBlocks(fromSelectionIn:)` via an injectable block-range map so it tests without a live `NSTextView`, `createExtract`, `append`, `passageBlocks(from:payload:)`), `defaultTitle`, and the extract-references-notes-only coercion.
- **Files:** NEW `Core/SourceAnchor+NotePassage.swift`, `Core/ExtractBuilder.swift`, `Core/NotesPassagePayload.swift`; MODIFIED W2 `Core/SourceAnchor.swift` (confirm `.notePassage` case + on-disk `note:`/`display:` serialization round-trip). Update `ArchiveNotes/macOS/project.yml` only if new files aren't glob-included (they should be).
- **Steps:** implement helpers → builder → wire `NoteStore.createItem/saveItem/addMembership/copyAssets` calls (W2 APIs) → coercion of non-note anchors to freeform.
- **Verify:** `xcodegen generate` in the worktree + clean `xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build` (no new warnings); run `ExtractBuilderTests`, `SourceAnchorNotePassageTests`, `ExtractTitleTests` (see §Tests). No GUI. **Tier-1** (§12 — pure model; writes go only through W2's already-audited `NoteStore`/`NotesTagProjector`; tests use a `mktemp` scratch store).
- **Done:** builder round-trips selection→blocks→`.md`→reload with byte-stable markdown; non-note anchors coerced; flip `SUITE_TODO.md` → *W7·S1 Extract model+builder*.

### S2 — Create Extract command + Notes-passage copy/paste round-trip
- **Scope:** the **Create Extract** menu item + `⌘⌥E` keystroke in the Note window (Selection menu); **Append to Extract…** (choose an existing extract) for segmentation; the copy handler's `com.archivenotes.passage` representation (W3 editor copy path) and the extract editor's paste branch (§5); UTI declaration in Info.plist.
- **Files:** NEW `Views/ExtractCommands.swift` (menu/keystroke → `ExtractBuilder`); MODIFIED W3 editor copy/paste handler (add one representation + one paste branch, marked `// W7`); MODIFIED `ArchiveNotes/macOS/Sources/ArchiveNotes/Info.plist` (`UTExportedTypeDeclarations` for `com.archivenotes.passage`); MODIFIED the Note-window commands (W6).
- **Steps:** wire command → `createExtract(into: currentExtractFolder)` → open/select the new extract in the Extract window; wire Append; add copy representation; add paste branch + invariant coercion.
- **Verify:** clean build + no new warnings; `PasteboardPassageTests`; **GUI via `./launch.sh notes`**: create a note with two blocks, select across both, run Create Extract → an extract with two `note-passage` blocks appears and is selected in the Extract window (drive with `cliclick` menu click + verify via the on-disk `.md`); copy a note passage, paste into an existing extract → appended block with provenance; paste plain external text → freeform block. **Tier-1**.
- **Done:** both creation paths produce identical provenanced blocks; segmentation append works; flip `SUITE_TODO.md` → *W7·S2 Create/append + copy-paste*.

### S3 — Jump-to-source + provenance chips
- **Scope:** `ExtractBlockHeaderView` (back-link chip + jump button), the live-title resolve (async, coalesced), the scroll-to-block plumbing (`scrollBlockRequest`), and all graceful-degradation paths (deleted note, stale ordinal, wrong kind).
- **Files:** NEW `Views/ExtractBlockHeaderView.swift`; MODIFIED W3 block renderer (host the header above `note-passage` blocks in the Extract editor); MODIFIED W4 `NotesNavigation.openItem(id:block:)` call sites / MODIFIED the Note editor view to observe `scrollBlockRequest` → `scrollRangeToVisible`.
- **Steps:** render chip/button → wire `onJump` to `NotesNavigation.openItem` → add scroll counter to the Note-window `ViewerModel` → observe + scroll → degradation messaging.
- **Verify:** clean build + no new warnings; `NotePassageResolveTests` (parse + degradation); **GUI**: from an extract block, click Jump → the Note window raises, selects the source note, and scrolls to the correct block (`cliclick` click on the button, screenshot); delete the source note → chip greys, jump shows the preserved-text status. **Tier-1**.
- **Done:** jump navigates + scrolls; provenance chip shows live title (renamed source updates) with snapshot fallback; degradations non-crashing; flip `SUITE_TODO.md` → *W7·S3 Jump-to-source + provenance*.

### S4 — Extract-viewer featuring (kind filter defaults + segmented control)
- **Scope:** per-window `KindFilter` default (Note=`.notes`, Extract=`.extracts`), the `notes|extracts|both` segmented control in both toolbars, the DB-predicate list query, and the extract-only "Sources" column/inspector summary.
- **Files:** MODIFIED W6 `ViewerModel` (add `kindFilter` + persistence keys if W6 hasn't; predicate `WHERE kind IN (…)`), MODIFIED the two window views (toolbar `Picker(.segmented)`, column set), NEW `Views/ExtractSourcesColumn.swift` (distinct-source-note count).
- **Steps:** add/confirm `KindFilter` on the model → set window defaults → bind segmented control → adapt columns → distinct-source count from block anchors.
- **Verify:** clean build + no new warnings; `KindFilterQueryTests` (predicate maps correctly, counts distinct notes); **GUI**: Extract window opens showing only extracts; toggle to `both` shows notes too; Note window defaults to notes; the Sources column shows the correct count for a segmented extract. **Tier-1**.
- **Done:** each window features its kind by default and toggles cleanly; flip `SUITE_TODO.md` → *W7·S4 Viewer featuring*; if all of S1–S4 shipped, flip the top-level **W7 Extracts** checkbox and delete `execution-plans/archive-notes/07-extracts.md`.

## Tests
Unit (XCTest, on a `mktemp` scratch store — never the real corpus):
- `SourceAnchorNotePassageTests` — `notePassage(...)` builds the §8.2 URL; `notePassageTarget` parses `open?id=…#block-n`, the legacy `note/…#block-n`, and rejects malformed/non-passage links; on-disk header serialize↔parse round-trip preserves unknown fields (00-overview §6).
- `ExtractBuilderTests` — single-block selection → one block; cross-block selection → one block per covered source block, each anchored to the right ordinal; freeform source block still yields a `note-passage` anchor; inline-image bytes snapshotted (copied, not referenced); discontiguous multi-selection ordering; empty selection → `[]`.
- `ExtractTitleTests` — `defaultTitle` strips Markdown, truncates on word boundary, falls back for image/whitespace-only.
- `ExtractSnapshotIndependenceTests` — create extract from a note, then mutate the source note's text/assets → extract `.md` bytes and asset bytes unchanged (D7).
- `ExtractRejectsNonNoteAnchorsTests` — a payload/paste carrying a reader/zotero anchor coerces to `freeform` (extract references notes only).
- `PasteboardPassageTests` — copy writes plain+RTF+`com.archivenotes.passage`; paste prefers the passage UTI, degrades to freeform otherwise.
- `NotePassageResolveTests` — resolve to existing note (in-range/out-of-range block), deleted note, wrong-kind id — each yields the specified status, none throw.
- `KindFilterQueryTests` — predicate for `.notes/.extracts/.both`; distinct-source-note count for a segmented extract.

GUI/behavioral (via `./launch.sh notes` + `cliclick`/XCUITest, S2–S4): Create Extract from a two-block selection; copy-note→paste-into-extract; plain external paste → freeform; Jump-to-source scrolls to the right block; deleted-source degradation; window kind defaults + segmented toggle.

## Risks & file-safety
- **No new write surface (keeps W7 Tier-1).** Every persistent write — new extract folder, `.md`, asset copies, `NotesTagProjector` subject/`ArchiveSuite` projection, membership rows/`organization.json` — goes through **W2's already-audited** `NoteStore`/`NotesTagProjector` (Tier-2 there). W7 must **not** add its own `FileManager`/`setResourceValue`/`setxattr` call. Asset snapshotting is done by *W2's* copy helper; if that helper does not exist, it is a **W2** addition (Tier-2), not W7.
- **Never the real corpus, never the source note's files.** Extract creation only ever writes into the *new extract's own UUID folder* in the Notes store; the source note is read-only during snapshot; jump-to-source is pure navigation. All tests run against a `mktemp` scratch store (memory `archive-test-run-safety`; Reader Prime Directive). Confirm the write-surface lint (00-overview / Reader Safety §13, adapted for Notes) still passes.
- **Snapshot fidelity vs. link drift.** Ordinal block anchors can go stale if the source note is edited; mitigated by graceful degradation (§3) and *§OQ1* (stable block GUID) — never a crash or data loss, since the snapshot text is self-contained.
- **Inline-image bloat.** Snapshotting image bytes duplicates data into the extract; acceptable for durability/independence. Large images: reuse W3/W4's thumbnail/downscale path if one exists; otherwise copy as-is (correctness over size — Working-directive guardrail).
- **Pasteboard payload trust.** Treat the pasted `com.archivenotes.passage` JSON defensively (decode with `try?`, validate the `sourceNoteId` is a UUID, clamp indices); a malformed payload degrades to a plain-text freeform paste, never a crash.
- **Extract-references-notes-only invariant** is enforced in one place (the anchor coercion in `ExtractBuilder`/paste) and covered by a test, so a future reader/zotero paste can't silently attach an outside-doc source to an extract.

## Open questions (non-blocking, later iteration)
1. **§OQ1 — stable block identity.** §8.2 locks ordinal `#block-<n>`; a per-block GUID (proposed for W2's `Block`) would make jump-to-source robust across source edits. Ship ordinals now (spec-compliant, degrades gracefully); revisit when W2 adds block ids.
2. **Two-way provenance.** Should a source note show a badge "N extracts derive from this note" (reverse index over `note-passage` anchors)? Cheap to add later from the FTS/organization tables; deferred.
3. **Extract → Scrivener.** Extracts are `archivenotes://open?id=…` targets like notes; confirm the Scrivener round-trip during W4 GUI (00-overview §15.6) covers extracts too.
4. **Re-snapshot / refresh.** A user may want to *pull* the source note's current text into an existing extract block (opt-in, explicit — never automatic, to preserve D7). Deferred.
5. **Author inheritance.** Default extract `authors = []`; some workflows may want to inherit the source note's authors. Left to a future preference rather than a silent default.
