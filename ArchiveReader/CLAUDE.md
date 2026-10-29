# Archive Reader — Project Guide

A native macOS app that lets a **historian read through PDFs of historical documents** tagged by the sibling
app **Archive Processor**: find tagged PDFs, list them chronologically, filter by subject / quality /
read-state, read them two-up (image + OCR text), copy text and file links, and mark them Read.

This file holds the rules and commands; it is the durable record for the Reader. **Core Directive**,
**Verified Facts** and **Safety Protocol** are settled and non-negotiable. Reference detail (facts tables,
architecture, implementation map, keyboard map, options, history) is in [`REFERENCE.md`](REFERENCE.md) — read
it on demand. It adds mechanism and history; it never relaxes a rule here, and a rule stated more strictly there still binds.

---

## CORE DIRECTIVE (bulletproof — this overrides everything)

Archival image files are **irreplaceable** and their tagging was **extremely time-consuming**.

- The app **MUST NOT** delete, move, rename, trash, re-save, or alter any file's **bytes/contents**
  or **location** — ever.
- The app **MUST NOT** mangle, drop, or lose any tag *unintentionally*.
- The app **MAY edit macOS Finder tags** — add / remove / change subject, date, quality, color,
  and read-state tags, for a single file **or a group** — but **only** as a *deliberate user
  action*, routed through one audited choke-point (`TagWriter`), applied as a precise **delta**
  (add-set / remove-set) to a **freshly-read** tag array, and **verified** afterward. Finder-tag
  (extended-attribute) metadata is the only change to existing archive files; their **bytes and
  location never change**. (Read/Unread triage is just the fast-path preset of this same editor.)
- **One named exception: the first archive-link copy** may create `.archive-suite-root.json`, a small
  identity file at the granted root, so links travel with the folder. It is created once, never
  rewritten; no existing archive file is touched. Choosing/reopening a folder, browsing, tagging,
  and ordinary text/file-link copying create no marker. If it is removed, browsing leaves it absent;
  another deliberate archive-link copy creates a new identity, and earlier links no longer resolve.
  A damaged/unreadable marker is left untouched; a failed creation refuses the copy with an explanation.
- Everything else — discovery, filtering, viewing, ordinary copying — is strictly **read-only**.

This is an architectural property, not a coding-discipline hope: **all tag writes route through the
single audited `TagWriter`** (see Safety Protocol). No other code imports a file-mutating API, and
even `TagWriter` never calls a move / rename / delete / content-write API — only the tag-array and
(deliberately) the color-label metadata. The root-identity exception uses ArchiveCore's coordinated
`RootMarker.ensure`, only from `RootFolderStore.prepareMarkerForLinkCopy`.

---

## Verified Facts (measured against the real corpus + Archive Processor source, 2026-07-04)

The full facts (corpus sample, tag read/write APIs, every facet, page-2 header format, segments, discovery,
sort key) are in REFERENCE.md under this heading. The rules they carry:

- **The SPEC wins.** The tag/PDF contract is authoritative in [`../SPEC/tag-format.md`](../SPEC/tag-format.md);
  if these facts ever disagree with it, the SPEC wins and both must be reconciled.
- **Tags are read from the Finder-tag xattr** (`ArchiveCore.TagReading`); never treat a search index as tag truth.
- Keeping the color-name token (`Red`/`Purple`) in the tag array preserves `labelNumber` without writing it —
  **still verify-after-write**.
- Years are **3–4 digits** — don't assume exactly 4. **Reader never authors a decade** (Processor-only); a year
  edit supersedes a decade (removes both tokens). Date Uncertain files sort by their speculative year, in italics.
- **Never lose any facet token.** Subjects can collide with other facets (a subject literally `1984`, `Q1`,
  `Read`): facet classification is display-only and **must never drive a destructive write**. Literal
  `Box`/`Folder`/`OCR Failed` tokens are plain subjects.
- **Do not hard-assume 2 pages.** Guard 1-page, >2-page, 0-page, corrupt/encrypted and tagged **non-PDF**
  images — degrade, never crash. Copy must work in whichever pane holds the selection (production image pages
  often carry a text layer).
- **Classification is NOT guaranteed present.** Segment-awareness is best-effort and degrades to
  filename-sequence order + manual multi-select; never build a core behavior that assumes it exists.
- Dataless cloud placeholders may be listed but are **never materialised** for content extraction.
- The chronological sort key is derived **from the Year/Month/Day tags** (no Processor change, no file writes);
  creation-date mirroring is deferred and **not** relied upon.

---

## Safety Protocol — `TagWriter` (the single write choke-point for ALL tag edits)

Every tag write — subject/date/quality/color edits, group edits, Read/Unread triage — goes through **one**
function, the *entire* write surface. An edit is a **delta** `{ add: Set<String>, remove: Set<String>, color:
ColorChange? }` (Read/Unread swap = `remove {opposite}, add {target}`; "set year to 1981" = `remove {matching
Year token(s)}, add {"1981"}`). All of these hold for every delta. Mechanism notes per rule (W14.2, W40.audit-ledger,
lint scope history): REFERENCE.md §Safety Protocol.

1. **Coordinated, metadata-only write.** `NSFileCoordinator` with `.contentIndependentMetadataOnly` — never
   `.forReplacing` (it can re-save content). Open PDFs for reading with `.withoutChanges`.
2. **Fresh read inside the write block** (no TOCTOU): re-read `.tagNamesKey` + `.labelNumberKey` immediately
   before computing/writing.
3. **Trustworthy-read guard (prevents the catastrophic tag-wipe).** If the read *throws* or returns `nil` tagNames, **ABORT** — never coerce a read
   failure to `[]`. Only a *confirmed* array may be written back. Applies to every edit. A file with genuinely zero tags is
   distinct from an unreadable file.
4. **Exact, whole-string, case-insensitive** matching for tokens to remove — never substring (removing `Unread`
   never touches `"Read later"`). Ambiguous target ⇒ **refuse and surface**, don't guess.
5. **Lossless new array:** `new = (fresh − remove) + add`, every untouched token verbatim, append order stable.
   Never build the write array from a persisted discovery row or any external index (both may be stale). A **no-op delta writes
   nothing** (no mod-date churn).
6. **Never request `.documentIdentifierKey`** (it can assign & persist an identifier — a mutation). Use
   security-scoped bookmarks and re-verify the resolved file's identity inside the coordination block before
   writing — it guards against writing to the wrong file after a Finder move; `FileIdentity` is
   `fileResourceIdentifier`, `isEqual:`-compared (`expectedIdentity:` / `expecting:`, armed at every live call site, captured lazily at edit time,
   never at bulk discovery; abort with `.identityMismatch`). The capture, every tag read and every write inside
   the block go through a **new `URL`** for the file, never the handed-in `URL`'s resource-value cache (a reused
   `URL` returns stale values and a write through it puts cached Finder info back on disk).
7. **Color label:** write `.labelNumberKey` **only** when the delta explicitly changes color; otherwise never
   write it — read before/after and restore only on unintended drift.
8. **Verify by re-read:** tag **multiset** equals `(old − remove) ∪ add` exactly; color as intended; file
   **bytes unchanged** (data-fork hash guard). Multiset, not order (macOS may reorder).
9. **No blind rollback / no blind restore.** On verify-fail, re-read and reconcile by re-computing the *delta*
   against current state — never rewrite a stale full array. **Undo = the inverse delta** (`add↔remove`) on a fresh read,
   so undo can never emit or destroy an unrelated token and it preserves concurrent third-party edits;
   bulk/group actions = **one** grouped undo. An undo never takes a token past its count before the change, and
   restores the label only while it still reads as the change left it (no stacking on repeat undo or re-tag).
10. **Group edits** show tri-state presence; "add X" touches only files lacking X, "remove X" only files having
    it. The Read/Unread fast path does **not** add a read-state token to a marker/neither file (hard-coded, not
    an Options toggle).
11. **Batch = independent idempotent units** (bounded concurrency), never all-or-nothing. Surface partial
    failures; a row leaves a filtered view only after its write **verified**.
12. **Append-only audit ledger** of `{path, bookmark, delta, before[], after[], timestamp}` for every change —
    history and inverse-delta undo source, *not* blind full-array restore. It lives in the app container, never
    the archive. Undo checks device/inode and bookmark identity (missing identity or a disagreeing bookmark
    refuses the file), consumes the whole group **before** applying inverses (never replayed after relaunch — occurrence additions
    are not idempotent), and
    a failed marker append refuses undo without changing tags. A forward recording failure warns and disables
    older undo until a synchronized history barrier persists. The 100-group undo window counts consumed groups,
    so older changes never resurface, and undo skips unsupported, undecodable and unverified ledger lines.
13. **PDF panes are provably non-writing:** PDFViews non-editable, annotations disabled, no `PDFDocument.write`
    path. The write-surface lint covers *all* write spellings (`setResourceValue(s)`, `setxattr`, `FileManager`
    mutators, `PDFDocument.write`) across `macOS/Sources/ArchiveReader`, `packages/ArchiveCore/Sources/ArchiveCore`
    and the tag-write/walker rules in `ArchiveNotes/macOS/Sources/ArchiveNotes`. The suite's entire permitted
    tag-write surface is three exact lines in `ArchiveCore/Tags/TagWrite.swift`; allowances are `(file, exact
    source line)` pairs, never whole files. ArchiveCore rejects `import AppKit` / `import SwiftUI` (so the thumbnail renderer stays on
    CoreGraphics/ImageIO and app-host screen suppression lives in each app target). The scope includes ArchiveCore
    because a Reader-only lint passed vacuously and missed the W26.deny tag-destroying bug; the mutation proof
    exists because a lint that cannot fail is exactly what this one was. The lint is
    one layer; the real guarantee is that only the audited writer touches tag-write APIs and *nothing* imports
    move/rename/delete/content-write APIs. **Run the lint (`scripts/lint-write-surface.sh`) and its mutation
    proof (`scripts/test-lint-write-surface.sh`) locally before committing Reader or ArchiveCore work.**

**Risk tiering (Verification & review policy; mirrors Archive Processor):** `TagWriter` and anything it touches
is **Tier-2 adversarial-review + property/integration tests on scratch copies** on every change. Never test tag
writes against the real corpus — always a copy. A change to `packages/ArchiveCore` is **Tier-2** and must
build+test all three apps (Reader + Processor + Notes); its own lane is `swift test` in `packages/ArchiveCore`.
The shared contract is the risk (a divergence would corrupt or mis-read irreplaceable data): both apps must interpret tags, date facets, quality, color/markers,
`Read/Unread` and the 2-page PDF + `Classification:` format *identically* — keep it in
[`../SPEC/tag-format.md`](../SPEC/tag-format.md). Keep `Core/` UI-free.

---

## Architecture — the rules (detail in REFERENCE.md §Architecture)

- **Filesystem tags are the sole truth**; only a clean completed pass may make absence authoritative.
  `LibraryIndex` and the FTS5 content index are **disposable, rebuildable caches** in OS SQLite — no third-party
  ORM/GRDB. Stale-row pruning stays the separate gated `pruneIfSettled` pass (gated on settled + non-empty +
  two-emission absence confirmation + component-boundary root scope), never folded into the indexing emission.
  Content-index `open()` is all-or-nothing; a dead or incomplete index is reported (amber status line), never
  answered as "no matches" (W23.m9). The subjects cache-rebuild signature is over the union (NOT the multiset)
  so even-count edits can't XOR-cancel.
- **The app never auto-groups.** Manual multi-selection is the definitive grouping; segment awareness is
  opt-in and degrades silently to plain selection when the classification is absent.
- **The menu bar is the single source of shortcuts** (`ArchiveReaderCommands.swift`); toolbars don't
  re-declare them. Full map: REFERENCE.md §Keyboard map. Bare-key triage equivalents (`]` `[` `\`,
  `Space`) fire only when the list has key focus (text-field-safe); `\` writes tags, so a bare key firing in a
  text field is an unintended tag write. All read-state mutation goes through `mark(.read)` → `TagWriter`
  (undoable).
- The nav list is an AppKit `NSTableView` (diffable, 150 ms-debounced filter, off the keystroke path); don't
  return to SwiftUI `Table`, which janked at 40k.
- The display calendar (W24.cal1-reader) is display only — sort, filter and tags keep ISO.
- **Dates are edited only in the ⌘I sheet**, the one date editor (owner, 2026-10-12); no inline date editing
  in the list. The inline subject editor commits the field's tokens on blur, WYSIWYG — a typed-but-not-Return'd
  word sticks (owner, 2026-07-08) — as ONE `TagWriter` delta.
- A **view / PDF-render** change needs a headless render guard (`RenderProbe` / `DocumentRenderGuardTests`);
  XCUITest sees the accessibility tree, not pixels. Snapshot references compare in the Tart VM and skip on the
  host; re-record only via the guarded guest-only flow in `ops/gui/README.md`.

## §Edge-case rules

- **Not exactly 2 pages / non-PDF / corrupt/encrypted:** probe open + page count; single-pane / "no OCR page"
  state; guard `PDFDocument(url:)==nil`. **Page count is never a defect signal** — merged >2-page PDFs are
  legitimate (`PDFFormatStatus`); flag a file only when unreadable or text-less. Tagged non-PDF images stay
  listed; the viewer degrades.
- **Neither Read nor Unread:** tri-state "No-read-state" bucket; markers stay visible, never silently lost
  (reached via the Options default, a smart folder, or saved view state — the picker offers All/Unread/Read).
- **Read-failure ≠ empty tags:** abort the write (Safety Protocol §3).
- **Duplicate filenames across boxes:** colliding rows show their containing folder (`DuplicateNames`);
  copied link groups carry full paths.
- **Unicode:** normalize (NBSP→space, dash-fold, case/diacritic-fold) for search/type-ahead/sort keys **only**;
  preserve real bytes for display + link encoding.
- **Multiple same-facet date tags:** deterministic rule + flag ambiguous.
- **Facet-looking subjects** (`1984`, `Q1`, `Read`): heuristics + display-only correction; never affects writes.

## §Decisions (settled with the owner; the app ships these)

- **Chronological sort key derived from tags** (medieval-safe, no Processor change); creation-date sort deferred.
- **Date Uncertain** sorts by its speculative year, rendered *italic* (never dumped to the end).
- **Discovery = owned filesystem truth** over the granted root; `LibraryIndex` is an OS-SQLite warm cache,
  FSEvents supplies live dirtiness, files tagged `Read`/`Unread` form the visible universe. No third-party ORM.
- **Subject filters AND by default** (ANY via the Options toggle or the tag cloud; no NOT); read-state is
  tri-state; "Mark Read" never adds a read-state token to a marker/neither file (hard-coded).
- **Facet classification is display/sort/filter only** — never drives a write.
- **Full tag editing is first-class** (single + group), always via `TagWriter`; free-form subjects with
  autocomplete + near-duplicate warning (`TagSimilarity`).
- **Reading/grouping is user-driven manual multi-selection** — never auto-groups; segment awareness is opt-in
  and degrades silently.
- **Full-text OCR search is in v1** via the app's content index (not Spotlight) + in-doc `⌘F`; bm25-ranked
  (name/classification/body weights), auto-refreshed when an index pass completes, `.relevance` sort during a query.
- **Smart folders are a scoped root** — a saved search enters a base scope; user filters layer on top (AND);
  Clear resets the user layer to the base set; a folder / All Files exits the scope; scope persists across
  relaunch (`LibraryFilter.effective(base:user:)`).
- **v1 stays sandboxed to one granted root.** Whole-Mac search is an unbuilt feature with a real cost (new code:
  walk N roots, merge, define exclusions; `FileAccessProvider` was never written) — **not** an entitlement or
  config toggle (corrected 2026-08-07, `W26.docs`; history in REFERENCE.md).
- **Viewer split, per-pane zoom and window size persist** as the next viewer's default (DV-1/DV-2), with **no**
  per-document reset, and are **not** Options toggles.

## Stack & Build

- Swift 6, SwiftUI (+ AppKit), **XcodeGen** — `project.yml` authoritative, `.xcodeproj` generated & gitignored.
  macOS 14+. Sandboxed to a user-granted archive root via a security-scoped bookmark (OS-enforced containment of irreplaceable files); changing that posture is
  new code, not a config change (§Decisions).
- Build: `xcodegen generate` then `xcodebuild -scheme ArchiveReader -configuration Debug build` (or `test`),
  with per-worktree DerivedData `-derivedDataPath ./build/DD`.
- Tests: `macOS/Tests/ArchiveReaderTests/` (unit, app-hosted) and `macOS/Tests/ArchiveReaderUITests/`
  (XCUITest, **off-screen VM only**). Write-surface lint + self-test as in Safety Protocol §13. No test
  count is kept here because it goes stale.

## Never
- Never write to the corpus during development/testing — copy files to the scratchpad first.
- Never hand-edit `.pbxproj` (edit `project.yml` + regenerate).
- Never add a tag-writing call outside the audited choke-point — since the W0 refactor
  `ArchiveCore.CoordinatedTagWriter`, *not* Reader's `TagWriter` (a delta adapter that calls no write API).
  The permitted surface is three exact lines in `ArchiveCore/Tags/TagWrite.swift`, so a tag write anywhere
  else — **including elsewhere in `TagWriter.swift`** — fails the lint.
- Never add a move/rename/delete/content-write call anywhere (not even in the writer). The three allowed
  exceptions in ArchiveCore are pinned line-by-line in the lint; adding a fourth is Tier-2.

Further ideas: `POTENTIAL_FEATURES.md`; open issues: `KNOWN_ISSUES.md`; manual smoke test: `SMOKE_TEST.md`.

## Reference (read on demand)

These sections are in [`REFERENCE.md`](REFERENCE.md), under the same headings:
- **Status** — shipped scope (v1 + P2 pass).
- **Verified Facts** — full facts (corpus, tag APIs, facets, page-2 header, segments, discovery, sort key); rules above.
- **Safety Protocol — `TagWriter`** — full original text with mechanism and as-shipped notes; rules above.
- **Architecture** — discovery, content index, reading model, windows, table, viewer, copy, Options panel.
- **§Keyboard map** — every shortcut, by window.
- **§Options** — the shipped Options panel and what did not ship.
- **§Edge-case rules — original wording**, **§Decisions — original wording** (rules above are authoritative).
- **§Decisions — history of the sandbox decision**.
- **Implementation map (shipped)** — file-by-file map, `packages/ArchiveCore`, tests, visual-render guards.
- **Stack & Build — detail**.
- **Archive Suite (long-term convergence with Archive Processor)** — shipped history.
- **Milestones**.
