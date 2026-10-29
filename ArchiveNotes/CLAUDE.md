# Archive Notes — App Guide

Provenance‑first note‑taking from archival PDFs (via Reader) and Zotero references, at
100k‑note / 2M‑word scale. Third app in the Archive Suite monorepo. Umbrella conventions,
the shared contract, and the release process live in the root [`CLAUDE.md`](../CLAUDE.md);
this file is authoritative for Notes‑specific work. It holds the rules and the commands; the file map,
per-file descriptions and backstory are in [`REFERENCE.md`](REFERENCE.md), read on demand.

## Core Directive — file safety

- Notes writes **only its own store** (UUID‑folder Markdown+assets under `Application Support/ArchiveNotes/Store`,
  which is inside the sandbox container — not the bare `~/Library/Application Support/ArchiveNotes/`; path in
  REFERENCE.md; a user-picked store is not wired yet, W40.fix-notes-choose-store). The archive corpus is **read‑only** —
  durable‑link resolution and page rendering only; no tag writes, no moves, no deletes on corpus files. ⚠️ That
  holds **by code discipline, not by the OS**: a granted archive root *is* writable from Notes. Nothing may write
  there; treat any code near a corpus URL as Tier-2.
- The **only** Finder‑tag writer is `NotesTagProjector` (W2), which mirrors title-cased front‑matter
  `tags` (subjects), the canonical Quality facet `Q1`–`Q3`, **and date into the existing
  Year/Month/Day/Decade facets** onto the note's own `.md` file via `ArchiveCore.CoordinatedTagWriter` —
  never onto corpus PDFs. Front-matter remains authoritative: `quality` 0/unrated writes no Q tag,
  invalid dates/quality values invent no tag, and a date update removes only facets recorded in the
  item-local ledger as actually introduced by Notes (the sent-with date, `W37`, uses the same facets and ledger).
  **Quality has no such ledger:** `Q1`–`Q3` are always Notes-owned, so a hand-applied `Q` token that
  front-matter does not hold (and that is not also a subject) is replaced or removed on the note's next save
  (`W19.q4`). The retired `ArchiveSuite` stamp is stripped lazily, on a note's next projection, not at launch.
  `authors` stay **front‑matter‑only**; an author facet remains a deferred owner decision. No Finder vocabulary
  beyond the shared subject, Quality and date contract (overview decisions **D2/D4/D9**).
- Test/scratch output goes to `mktemp` / `TESTOUT` — **never** the real store or corpus during dev/test.
- **Full protocol:** [`GUI_SAFETY.md`](GUI_SAFETY.md) — authoritative for test file safety: the scratch-corpus
  rules (never drive the store picker; confirm scratch before any tag write) + the DEBUG scratch-write guard that
  mechanically aborts any `NotesTagProjector` write outside scratch under a test / GUI-drive context.

## Stack & build

- **XcodeGen** — `macOS/project.yml` is authoritative; the `.xcodeproj` is generated and gitignored.
  `brew install xcodegen`, Xcode 16, macOS 14+, Swift 6. Depends on `packages/ArchiveCore`.
- **Build:** `cd ArchiveNotes/macOS && xcodegen generate && xcodebuild -scheme ArchiveNotes -configuration Debug -derivedDataPath ./build/DD build`
- **Run:** `./launch.sh notes` from the repo root, or `cd ArchiveNotes && ./launch.sh`.
- **Test:** `./test-smoke.sh notes` from the repo root, or `cd ArchiveNotes && ./test-smoke.sh`. It uses the
  `ArchiveNotesUnit` scheme and selects `ArchiveNotesTests`, so it cannot build the UI-test runner;
  `ArchiveNotesUITests` stays an explicit off-screen VM action.
- **GUI harness:** `scripts/make-notes-fixture.sh` builds a SCRATCH store and prints its path for the `#if DEBUG`
  `-ANUITestStorePath` override; `scripts/gui-drive-notes.sh` is scratch-only, never drives the store picker,
  and is **host-only, so unattended sessions are blocked from it**. The `ArchiveNotesUITests` suite runs
  **off-screen in the Tart VM** and is part of the periodic health gate. Catalog and owner-eye checks:
  [`scripts/GUI-HARNESS.md`](scripts/GUI-HARNESS.md).
- **Visual / render verification:** `ArchiveNotesUITests` asserts the accessibility tree, not pixels — it
  won't catch a PDF pane / page-thumbnail that renders blank; a render change needs a pixel guard
  (`RenderProbe` / `DocumentRenderGuardTests`, the `W9.b4` Notes thumbnail regression). For the running app use
  the live sighted loop (`ops/gui/capture-window.sh` + `cliclick` → read the shot,
  → [`../ops/gui/README.md`](../ops/gui/README.md)).
- **Durable-link E2E + safety (W8-S9):** `scripts/e2e-durable-links.sh` (build-free, GUI-free filesystem proof)
  plus `DurableLinkE2ETests` in the unit gate.
- **Bundle ID:** `com.archivenotes.app`. Signed with the suite's local self‑signed cert
  (`CODE_SIGN_IDENTITY: "Archive Suite Dev"`), not ad‑hoc and not notarized (root [`CLAUDE.md`](../CLAUDE.md)
  §*Conventions*). Notes' **Debug** entitlements (`ArchiveNotes.uitest.entitlements`) carry
  `disable-library-validation` + `get-task-allow`; the Release file must never gain either.

## Code invariants (moved here from the Implementation Map)

These were stated inside the file map; they are rules for anyone changing that code. The map itself is in
REFERENCE.md §Implementation Map.

- **Single seams — don't add a second one.** `NotesTagProjector` is THE audited Finder-tag mirror; its DEBUG
  scratch-write guard is test/GUI-drive only, off in the real app and out of Release. `Item.normalizedDate` is
  THE write-path date normalizer. `ReaderRootStore` is the only writer of `readerRootBookmarks`.
  `ReaderLinkResolver` is THE `archivereader://` resolve seam. `AssetPathResolver` is THE inline-image READ
  seam. `ItemAssetStore` is the single asset name arbiter. `InlineImageMarkdown` is the ONE owner of the
  `![alt](path)` and `[label](dest)` grammar, and its `isEscapable(_:)` is the ONE authority on which backslashes
  are escapes (two private copies is how the title and image paths came to disagree); the asset re-key matches
  with `destinationLiteral`, never an interpolated `](ref)`. Link destinations: reads are lenient, writes strict
  (`<…>` for anything containing `( ) < > \`, whitespace or a control character), so a hand-edited path heals on
  its next save (W3.notes-image-dest-paren); the pattern is possessive on purpose.
- **Never lose the user's text.** `FrontMatterCodec` never drops data: unknown keys round-trip byte-for-byte and
  unreadable `additional_dates` entries are written back verbatim (`NotesFrontMatterTests` fuzz). `MarkdownBridge`
  round-trips are idempotent and never drop text (unsupported styling degrades, text survives); a hard parse
  failure stays raw with a banner, never a lossy styled view (W9.d7). `NoteStore` writes atomically; delete is a
  coordinated move to Trash, and a file-presenter refusal preserves the note (W9.d12c). Metadata/Zotero writes
  (Auto-fill confirm, note-ref saves) go through NotesModel's atomic transactions, which preserve a concurrent
  body/title/tag edit (W9.b1, W9.b3). A failed subject edit is retried as the exact delta, never silently dropped;
  the pending-subjects journal keeps Finder-tag removal ownership across a relaunch; nothing retries
  automatically. The terminate flush is bounded and, on failure, offers copies, Retry, Don't Quit or Quit.
- **Dates.** `GregorianDay` validates every date input with arithmetic, NOT `Foundation.Calendar` (ICU's hybrid
  calendar is wrong for archival dates); Feb 29 is accepted under either reckoning (proleptic Gregorian or
  pre-1582 Julian), and `normalizedDate` downgrades an impossible day to the finest precision the string supports
  rather than rejecting it (W23.l4). Display calendars (`DisplayCalendarSettings`, ArchiveCore `Calendars/`)
  are display only — never the stored date; storage and `GregorianDay` stay unchanged. `Item.sortDate` must stay
  identical to ArchiveCore `DocumentTags.sortDate` (`ItemSortDateTests` is the tripwire).
- **Index and organization.** `NotesIndex.open()` is all-or-nothing: a failed PRAGMA/migration/schema step
  discards the handle. Tier-2 in Notes also covers the tag projector, org/replication transactions and the
  hard-delete path. Multi-row org transactions are whole methods, never an exposed BEGIN/COMMIT — no
  suspension between BEGIN and COMMIT (W23.m13). `OrganizationStore`'s `deleteFolder`, `moveMembership` and
  `deleteTemplate` move in-memory state ONLY after the DB transaction commits, and `moveMembership` inserts before it deletes so an item is never member-less. Both
  membership minting seams refuse an item whose confirmed hard delete is in flight (W23.h3-fu); removing the last
  instance asks first and re-checks fresh at confirm; `trashItems`
  holds OrganizationStore's hard-delete window for the whole call (W23.h3-fu) and drops an index row only once `NoteStore.itemExists` says the note is gone. The indexer never prunes on an
  empty/unsettled snapshot (two-emission gate). `isIndexReady` means SETTLED, not healthy — health is
  `NotesIndexer.failure`. NoteStore's projection ledgers are never authority.
- **Reader links.** There is NO synchronous full-walk API; `resolve` stays async-only so a main-actor archive
  walk cannot be reintroduced, and the basename walk runs off the main actor, cancellable and bounded. A search
  that did not finish is `.searchIncomplete`, NEVER `.notFound`; an unknown GUID / wrong folder needs a re-grant,
  never a silent result; an unavailable saved root requests access before any basename scan. Containment for both
  stages compares canonical (`resolvingSymlinksInPath`) paths component-wise, so a symlink cannot leave the granted
  root. `RoundupYearSuggestion` and `SourceBlockThumbnailRenderer` read only exact, already-granted roots: no
  prompt, no scan, no root mutation, no automatic writes. The Notes PDF pane is read-only, no-persist.
- **Assets and editor.** `AssetPathResolver` refuses anything outside the item's own `assets/`: a syntactic gate
  (`assets/`-rooted, no `..`, not absolute or remote) plus canonical component-wise containment, so a symlink
  cannot escape. `writeReservedAsset` never overwrites, never re-disambiguates, and stays inside component
  boundaries. Extracts reference notes only (reader-source blocks are coerced); the W9.b4 paste fallback keeps its
  durable block before upgrading the thumbnail asynchronously; pasted entries are capped at 100. The thumbnail `cacheKey` (max pixels + file
  version + path) is derived in `InlineImageAttachment`, never caller-supplied. The editor is TextKit 2 — no
  `.layoutManager` in `Editor/` (`EditorBindingTests` lints it). Block thumbnails stay inline in the body by design.
  The body model flushes the outgoing item before loading the next; a closed pane's flush is dropped only once
  saved, else it is kept with an `UnsavedDraftVault` copy and Retry.
- **Zotero.** `ZoteroUITestTransport` is DEBUG-only, gated by the GUI-test launch argument, and never opens a
  socket; Zotero tests never reach the network. When Zotero is down the client degrades to `.unavailable` and never
  throws to the caller; requests are bounded by a timeout. Clipboard detection is changeCount-gated, no timer. Only
  Auto-fill / `NoteZoteroInspector` fetch citations. Auto-fill cancel writes nothing.
- **Lifecycle.** The deep-link router holds a request until `isIndexReady` and forwards it exactly once (W9.b5).
- **Tests.** `NotesIndex.executeForTesting` and `NotesModel.hardDeleteWindowHookForTesting` are DEBUG-only seams,
  out of Release. Tests that touch `readerRootBookmarks` snapshot and restore it; fixture-harness window closes
  never overwrite the shared window size (W21). Safety tests stay non-vacuous: each escape case first asserts the
  pre-fix rule accepted the fixture; divergence tests compare memory against the database; fault injection is
  targeted by row; races are driven through a deterministic hook, not racing tasks.

## `00-overview.md` is the interface spec — keep it (owner decision 2026-07-29)

`execution-plans/archive-notes/00-overview.md` is the **authoritative Archive Notes interface spec**, and it is
deliberately **exempt from the "delete a shipped `execution-plans/` plan" convention** (root `CLAUDE.md`
§*Docs & backlog convention*) — it is not stale, and 65 references in shipped source and test comments cite its
sections. Do not delete or relocate it, and do not promote it to `SPEC/` (that would make a Notes-internal
document a cross-app contract under the all-three-apps Tier-2 unit). If you are tempted to "tidy" it away, read
the CLOSED item in `SUITE_TODO.md` §*Suite doc hygiene* first: the deletion has been mis-scoped twice. SPEC
edits were de-gated 2026-08-13, but the coupling cost stands, and that is what the argument rests on. Full
reasoning: REFERENCE.md.

## Reference (read on demand)

Moved to [`REFERENCE.md`](REFERENCE.md), under the same headings:

- **§Implementation Map** — the full source and test file map (`macOS/Sources/ArchiveNotes/`,
  `macOS/Tests/ArchiveNotesTests/`, `packages/ArchiveCore/`), per-file descriptions and wave tags. Its rules are
  in §*Code invariants* above.
- **§Core Directive — file safety (detail)** — the container store path and why the corpus is writable by the OS.
- **§Stack & build (detail)** — GUI harness fixture contents, check catalog, durable-link E2E detail, signing
  rationale pointer.
- **§`00-overview.md` is the interface spec — keep it — the reasoning** — the citation count and sections, and
  why not `SPEC/`.
