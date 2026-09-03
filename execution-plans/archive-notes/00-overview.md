# Archive Notes — Master Plan & Architecture (00 / overview)

> **Status: SHIPPED (W0–W8, 2026-07).** Archive Notes is built; the per-wave execution plans (`00a`, `01`–`08`)
> **shipped and were deleted** (git history keeps them). **This file is RETAINED** — not as an execution plan
> but as the **authoritative interface contract + architecture record** for the app: §2 locked design decisions,
> §5 front-matter schema, and **§16 Interface Contract** are cited by [`ArchiveNotes/CLAUDE.md`](../../ArchiveNotes/CLAUDE.md)
> (e.g. §16.1/§16.3/§16.4) and must stay in sync with it. (A future cleanup pass may fold §16 into
> `ArchiveNotes/CLAUDE.md` or promote it to `SPEC/` and then delete this file — tracked in `SUITE_TODO.md`.)
>
> The shipped, now-deleted wave plans (for orientation only — read the code + `ArchiveNotes/CLAUDE.md` for current truth):
> - `00a` ArchiveCore extraction · `01` scaffold + 3-pane shell · `02` store/front-matter/virtual-folders/FTS5 ·
>   `03` WYSIWYG editor · `04` sources + cross-app links · `05` Zotero · `06` viewers/search/replication/templates ·
>   `07` extracts · `08` tests + GUI harness. All landed; see `SUITE_TODO.md` Wave W0–W8 records + git log.

---

## 1. Vision & the real workflow

Archive Notes is a **provenance-first, segment-optional note-taking app** for a historian/writer working
from archival sources (oral histories, letters, corporate documents, periodicals) plus books. The design
target is the owner's real corpus — cf. the DevonThink screenshot: a *Meritocracy / Silicon Valley book*
project with a deep numbered folder tree, 580+ items per search, tags along the bottom, a rich-text detail
pane, and heavy back-and-forth between reading and writing.

The single most important property is **reliable, durable provenance**: every note must make clear *where
its content came from* and stay usable **even if this app is never developed again**. The second is
**flexibility**: notes must not force the user to decide segment boundaries, because in archives the
boundary between "documents" is frequently unclear (an unbroken run of letters, mixed folders). The app
must make single-PDF ("well-identified segment") reading *easy* without ever *requiring* it.

The observed loop:
1. **Read in Archive Reader** (the PDF corpus), go back and forth to Notes.
2. **Copy** text/screenshots from the PDF in Reader → **paste** into the relevant part of a Note in Notes.
3. Optionally **Create Extract** from a note passage → curate the most relevant text in the Extracts window,
   abstracted away from the full provenance apparatus.
4. Organize with a **virtual folder tree + replication** (working-sets), search by keyword+tag, sort by date.
5. Write the actual prose in **Scrivener**, inserting durable hyperlinks that jump Scrivener → Notes →
   (select in) Reader → the PDF.

**Design philosophy — DevonThink is a reference for ONE thing only.** The pasted DevonThink screenshot
models *only the basic three-pane browsing shell* (a folder/source tree · an item list · a detail pane) and
the fact that replication + tag-based browse are useful. It is **not** a model for how notes look, how
sources/links/provenance are presented, how tags are entered, or how anything else behaves — do **not**
mimic DevonThink's chrome, its link rendering, its tag bar, or its item styling. The whole point of Archive
Notes is to be **history-specific**: to keep DevonThink's genuine benefits (replicants/working-sets, fast
tag+keyword browse at scale) while shedding its drawbacks for this use case, and to build purpose-made
surfaces for the things that matter here — reliable provenance blocks, page-preview-headed source areas,
Reader/Zotero links, precision+uncertain dates, extracts. When a wave says "3-pane" it means the *shell*;
every other surface is designed from the historian's workflow up, not copied from DevonThink.

---

## 2. Locked design decisions (owner-confirmed 2026-07-10)

| # | Decision | Choice | Consequence |
|---|----------|--------|-------------|
| D1 | On-disk note/extract format | **Markdown + assets**, one **UUID-named folder** per item: `<store>/<uuid>/<Title>.md` + `<uuid>/assets/` | Durable, greppable, tool-agnostic; title=filename with no collisions; UUID = stable link identity |
| D2 | Metadata store | **YAML front-matter is authoritative** for *all* metadata; mirror subject tags, the canonical `Q1`...`Q3` Quality facet, and date into the existing Year/Month/Day/Decade Finder facets (regenerable projection, not source of truth) | No new vocabulary or author facet; front matter remains the durable answer |
| D3 | Organization / replication | **Purely virtual** — flat pile of UUID folders on disk; the folder tree, "home", working-folders, and replication are **many-to-many records in the index DB** | Replication is trivial (a membership row); moving computers = move one folder; disk is not the tree |
| D4 | Shared-tag SPEC change | **No corpus back-fill** this run | **No `Author:` facet**; existing corpus untouched (lowest risk) |
| D5 | Durable link identity | **Root-marker file (GUID+name) + root-relative path**, carried in custom URL schemes | Survives moving the whole install to a new computer after a one-time root re-grant |
| D6 | Editor | **Rich-text WYSIWYG + formatting toolbar**, Markdown as the saved format, with a **per-note raw-Markdown toggle** | `NSTextView`/TextKit + attributed↔Markdown bridge; user never sees syntax unless they ask |
| D7 | Extract semantics | **Snapshot + provenance link** (extract owns editable text; link back to source note+passage; jump-to-source; note edits don't change the extract) | Extract has its own title/date/author/tags; can be segmented with blocks linking to *different* notes |
| D8 | Zotero | **Read metadata** via Zotero's local HTTP API / Better BibTeX (auto-fill author/date/title + formatted citation), degrade gracefully if Zotero isn't running | Paste `zotero://select/…` (item **and** attachment) → chip + fetched metadata; note-level and per-block |
| D9 | Quality ("ordering") tag | Front-matter `quality: 1..3` (3 = highest), **Quality UI** (dedicated control, not a free-form tag) | Projects canonical `Q1`...`Q3` onto the note's own `.md`; `0`/unrated projects no Q token |
| D10 | App shape | A **third native macOS app** `ArchiveNotes/` (bundle `com.archivenotes.app`), sandboxed like Reader + `network.client` for Zotero localhost | Own 3-pane windows (Notes viewer + Extracts viewer); reads Reader's corpus only via durable links |

**Deferred to future iterations** (explicitly out of scope for run 1, tracked in §13): the unified single
storage path for all three apps; mirroring author into Finder tags; multi-root corpus support;
iOS/companion anything.

---

## 3. Data model (entities)

All authoritative data lives in the `.md` front-matter + body. The index DB (`03`, `02`) is a **disposable
cache** rebuildable from the files — *except* the folder/replication membership graph and template
assignments, which are **app-owned organizational data** with no natural home in an individual file, so they
are stored durably in the index DB **and** exported to a human-readable JSON sidebar file for portability
(see `02`). The rule: *content + per-item metadata* → the file; *cross-item organization* → the DB (+ JSON export).

### 3.1 Item (Note or Extract)
A **unified** underlying type; `kind: note | extract` in front-matter differentiates them for the user and
for which viewer features light up. Fields (front-matter, §5):
- `id` (UUID, immutable — the folder name and link target)
- `kind` (`note` | `extract`)
- `title` (mirrors the `.md` filename; rename keeps them in sync)
- `authors` ([String], 0..N) — front-matter only (D2)
- `date` + `date_precision` (`decade|year|month|day`) + `date_uncertain` (Bool) — see §7
- `quality` (Int 1..3, optional; `0` means unrated/no value) — D9, mirrored as Q1...Q3 per D2
- `tags` ([String], subjects; the shared controlled vocabulary — mirrored to Finder tags per D2)
- `sources` — ordered per-block source anchors (§3.3); at item level, a convenience union of block sources
- `zotero` — Zotero refs at item level (§3.4)
- `created`, `modified` (ISO-8601)
- `roundup` (Bool, optional) — marks a "round-up" note (§3.5)
- `schema` (Int) — front-matter schema version for forward-compat

### 3.2 Block
The body is an **ordered list of blocks**. A block = *(optional source anchor) + rich-text/Markdown body +
inline images*. Blocks are the unit of provenance; **tags are never per-block** (owner: tags apply to whole
notes only). On disk a block is delimited by a **self-describing Markdown source header** (§6) so the raw
`.md` is fully legible without the app. Block kinds by source anchor:
- **freeform** — no source (plain writing).
- **reader-page** — anchored to one page of a Reader PDF (carries a page-preview thumbnail header).
- **reader-doc** — anchored to a whole Reader PDF (a "well-identified segment": book / single doc / single
  PDF holding several letters).
- **zotero-item** / **zotero-attachment** — anchored to a Zotero library item or a specific attachment.
- **note-passage** — *(extracts only)* anchored to a passage in a source Note (§7).

### 3.3 SourceAnchor
`{ type, link, display, page?, thumbnailRef?, citation? }` where `link` is a durable URL (§8) and `display`
is a stable human label (e.g. `Gordon E. Moore Oral History — p. 41`). `thumbnailRef` points into the item's
`assets/` for a cached page image. This is the single structure both the block header (Markdown) and the
index encode. **A single block may carry BOTH a `link` (a Reader document) AND a Zotero `citation`/select
link** — this is the owner's "the document lives in Reader but its citation lives in Zotero" case (R12c):
the block renders a reveal-in-Reader control *and* a Zotero citation chip side by side (see `04` §block-paste
and `05` §per-block chips).

### 3.4 Zotero reference
`{ selectLink: "zotero://select/…", itemKey, library, kind: item|attachment, citation?, fetched? }`. Item-
level (whole note cites a Zotero source) or per-block. Multiple allowed (owner: "multiple Zotero items").

### 3.5 Round-up
A note whose blocks anchor several **loosely related** PDFs (not one segment), conventionally within a
single year. Modeled as an ordinary note with `roundup: true` and multiple `reader-doc`/`reader-page`
blocks; the year constraint is a soft UI affordance (offer to set the note's date to that year), not enforced.

### 3.6 Folder & Replication (virtual — D3)
- **Folder**: `{ id, name, parentId?, sortOrder, templateId?, kind: normal|smart }`. A user-creatable,
  movable tree. `smart` folders store a saved query (keyword+tags+kind+date) and behave as a scoped root
  (mirrors Reader's shipped smart-folder-as-scope behavior).
- **Membership (replication)**: a many-to-many `{ itemId, folderId, addedAt }`. An item shown in K folders
  has K membership rows — these are DevonThink **replicants** (one underlying file, many places). Removing a
  membership removes that replicant. **Removing the *last* membership** triggers the mandatory
  "sole remaining instance — this will delete the note itself" confirmation, then deletes the item's folder
  (files) after the guard (§9, `06`).

### 3.7 Template
`{ id, name, kind: note|extract, bodyMarkdown, frontmatterDefaults }`. Assigned to a folder (`Folder.templateId`);
"New from template" inside that folder (or a child, inheriting) instantiates it. Stored as real template
`.md` files in a `Templates/` area + a small store (see `06`).

### 3.8 RootMarker
`{ guid, name, createdAt, kind: reader|notes }` — a tiny JSON file dropped at a granted root folder to give
it a **portable identity** (§8). Not per-file; per-root.

---

## 4. On-disk layout

```
<NotesStore>/                         # user-chosen folder (security-scoped bookmark) OR app-default on first run
  .archive-suite-root.json            # RootMarker {guid,name,kind:notes} (§8)
  items/
    7f3a9c21-…/                        # one folder per item; folder name = id (UUID)
      Moore on Intel culture.md        # title = filename (rich text ⇄ markdown)
      assets/
        p41-thumb.png                  # cached Reader page-preview headers
        pasted-2026-07-10-1.png        # user-pasted screenshots
    b1d4e0f7-…/
      Noyce resigns from Fairchild.md
      assets/…
  Templates/
    Oral history note.md
    Letter note.md
  organization.json                    # human-readable export of folders + memberships + template assignments
                                        #   (durable mirror of the DB organizational graph; §2, 02)
```

- **Index DB** (disposable cache) lives *outside* the store, in `~/Library/Application
  Support/ArchiveNotes/notes-index-v1.sqlite3` (mirrors Reader's `content-index-v2` posture). Rebuildable
  from `items/**/*.md` + `organization.json`.
- Moving computers = copy the whole `<NotesStore>/` folder; IDs, titles, memberships (`organization.json`),
  and the root marker all travel; the index rebuilds; durable links resolve after a one-time re-grant.

---

## 5. Front-matter schema (authoritative metadata)

YAML front-matter at the top of every `.md`. Example (a **note**):

```markdown
---
schema: 1
id: 7f3a9c21-4b2e-4d1a-9c33-8e5f0a1b2c3d
kind: note
title: Moore on Intel culture
authors: [Gordon E. Moore]
date: 1968
date_precision: year          # decade | year | month | day
date_uncertain: false
quality: 3                     # 1..3, optional (3 = highest); Quality UI; projects Q3
tags: [Silicon Valley, Intel, Corporate Culture]
roundup: false
zotero:
  - selectLink: zotero://select/library/items/ABCD1234
    itemKey: ABCD1234
    library: library
    kind: item
    citation: "Moore, Gordon E. Oral History. Chemical Heritage Foundation, 2001."
created: 2026-07-10T21:00:00Z
modified: 2026-07-10T21:05:00Z
---

<!-- block: reader-page
     link: archivereader://reveal?root=7F3A…&rel=SV/Business/Moore.pdf&page=41
     display: "Gordon E. Moore Oral History — p. 41"
     thumb: assets/p41-thumb.png -->
![Gordon E. Moore Oral History — p. 41](assets/p41-thumb.png)

Moore says he and Noyce were **responsible** for Intel's early egalitarian culture…

<!-- block: freeform -->
My own gloss: this cuts against the "Noyce as sole culture-setter" story…
```

- **Block delimiters are HTML comments** (`<!-- block: … -->`): invisible in any rendered Markdown view,
  fully legible in raw text, and standard-Markdown-safe. The thumbnail is *also* written as a normal
  `![alt](assets/…)` image so the provenance header renders even in plain TextEdit/Obsidian.
- **Extracts** use the same schema with `kind: extract` and `note-passage` block headers (§7).
- **Schema evolution**: additive only; unknown keys preserved on round-trip (never dropped); `schema`
  bumped when the reader must special-case older files.

The Finder-tag **mirror** (D2) writes exactly `tags` (title-cased per the shared convention), nothing else,
via the audited projector (§9). It is regenerable from front-matter and never the source of truth.

---

## 6. Block source header format (self-describing Markdown)

Each block begins with a one-line HTML-comment header the app parses, followed (for sourced blocks) by a
rendered thumbnail image line. Grammar (stable, versioned with `schema`):

```
<!-- block: <kind>
     [link: <durable-url>]
     [display: "<human label>"]
     [page: <int>]
     [thumb: assets/<file>]
     [zotero: <select-link>]
     [note: <archivenotes://open?id=<uuid>#block-<n>>] -->
```

Round-trip rule: the parser tolerates missing optional fields and **preserves any unrecognized fields
verbatim**. If the header is absent, the region is treated as a single `freeform` block (graceful
degradation — matches the SPEC's "consumers must degrade, never assume structure" ethos).

---

## 7. Dates

Owner's date model maps 1:1 onto Reader's existing facet semantics (`SPEC/tag-format.md`), so chronological
sorting is *identical* to the corpus:
- `date_precision: decade | year | month | day` with `date` holding the most precise known value
  (`1970` for a decade means the "1970s" start year, per the SPEC decade rule).
- `date_uncertain: true` flags a speculative date — the item **still sorts by that date** (rendered
  italic), never dumped to the end (mirrors Reader).
- Sort key = the SPEC's `sortDate` formula (`year*10000 + month*100 + day`), reused verbatim from
  `DocumentTags.sortDate` (shared via ArchiveCore, §10).
- UI: a compact date control offering the four precisions + an "uncertain" toggle (`06`).

Dates remain **front-matter-authoritative**. Their regenerable Finder projection uses only the existing
Year/Month/Day/Decade facets (`1960s`; `1968`; `03 March`; `Day 5`) — no new vocabulary or SPEC change.

---

## 8. Durable links & URL schemes (D5)

### 8.1 Root marker
On first grant of a Reader archive root **or** the Notes store, drop `.archive-suite-root.json`
=`{guid, name, kind}` at the root (idempotent; never overwrites an existing guid). This gives the root a
**portable identity** independent of path/username/volume.

### 8.2 Link forms
- **Reader document/page** (Notes → Reader): `archivereader://reveal?root=<GUID>&rel=<url-encoded relative
  path under the root>&page=<optional int>`.
- **Notes item** (Scrivener/Reader/Notes → Notes): `archivenotes://open?id=<UUID>` (opens/reveals the note
  or extract in Notes; `#block-<n>` fragment optional for a passage).

### 8.3 Resolution
- **Same machine**: resolve `root` GUID → the currently-granted root URL (from the root store), join `rel`,
  verify existence. On a page link, also pass `page` to the reveal.
- **New machine**: after the user re-grants the root once (Reader already re-prompts for a stale bookmark),
  the GUID in `.archive-suite-root.json` matches the stored one → links resolve. If the GUID is unknown,
  surface "This link points at an archive root that isn't set up on this Mac — choose it?" (a guided
  re-grant), never a silent failure.
- **Fallbacks** (in order): exact rel path → same basename elsewhere under root (offer) → "document not
  found in the current archive" message. Never open a raw file outside the granted scope.

### 8.4 Reader-side additions (see `04`)
Reader gains: `CFBundleURLTypes` (`archivereader`), an app-level deep-link **router** + `.onOpenURL`, a
public `NavigationModel.revealAndSelect(paths:)` built on the *existing* in-process select+scroll primitive
(clears filters/scope, then defers the reveal until the target appears in the library — or until *settled
absence* gives up; re-worded 2026-08-07 by `W26.docs`, it used to say "until the Spotlight gather completes",
and since `W26.walk2` the wait is on the `CorpusWalker` pass, not a Spotlight gather. **The contract Notes
depends on is unchanged**: a link handed over before discovery finishes still resolves once the file shows
up, and a link to a file that genuinely isn't there still fails honestly rather than hanging), and a
**"Copy Archive Link(s)"** command
that writes a multi-representation pasteboard item: the `archivereader://reveal…` URL(s) as plain text **plus**
a custom-UTI JSON payload `[{link, display, page, thumbnailPNGbase64?}]` that Notes reads on paste to build
source blocks in one step. These are **read-only w.r.t. the corpus** (Tier-1/2, no `TagWriter` change).

---

## 9. Finder-tag mirror — the one file-safety surface (D2)

Notes is authoritative in front-matter, but it **does** write a narrow Finder-tag projection (subjects, the
canonical Q1...Q3 Quality facet, and existing Year/Month/Day/Decade date facets) onto its own `.md` files.
Writing Finder tags is the one place Notes touches the
irreplaceable-data safety envelope, so it obeys **every** invariant proven in Reader's `TagWriter`:
1. Single audited choke-point (`NotesTagProjector`, `02`), `NSFileCoordinator(.contentIndependentMetadataOnly)`.
2. **Trustworthy-read guard** — a failed/nil read aborts; never coerced to `[]` (the anti-tag-wipe rule).
3. Lossless delta: `new = (fresh − remove) + add`; untouched tokens preserved verbatim.
4. Verify-by-re-read (multiset-equal) before returning success.
5. Only ever adds/removes projected subjects, Quality, and date facets; date removals use the hidden
   per-item ledger of facets Notes actually introduced, so a matching third-party Finder tag is never
   adopted. The one-way R13d cleanup strips the exact retired `ArchiveSuite` stamp while preserving every
   other tag.

Because Notes writes **only its own newly-created files**, and never the Reader/Processor corpus, the blast
radius is bounded — but the invariants are non-negotiable (Tier-2 for anything in this projector). See `08`
for the adversarial tests (tag-wipe attempt, concurrent write, unreadable file, retired-stamp strip, and an
ordinary subject literally named `ArchiveSuite`).

---

## 10. Shared code: the ArchiveCore decision (D + engineering judgment — flag for owner)

Adding a *third* consumer of the tag/PDF/date contract is exactly the forcing function the Suite has been
deferring (`SPEC/tag-format.md` L208-209; `ArchiveProcessor/POTENTIAL_FEATURES.md`). A third hand-rolled
parser is the specific silent-divergence risk the SPEC warns about. **Decision (owner-confirmed 2026-07-10):
do the FULL ArchiveCore extraction and migrate all three apps — and do it FIRST, as Wave 0, before any
Notes-specific work.** Detailed in `00a-archivecore-refactor.md`.

- Introduce a **`ArchiveCore` Swift package** (`packages/ArchiveCore/`) seeded **from Reader's & Processor's
  existing, tested** code, containing the **UI-free** shared contract: the tag vocabulary + facet model +
  parser (`DocumentTags`, `sortDate`, `isDateFacetLike`, `ArchiveColor`), the tag **read + write** path
  (`TagReading`, `TagWriter`, `TagEditing` — the audited choke-point with all seven invariants),
  `PDFTextExtractor` + `PDFFormatStatus`, the Processor's tag **vocabulary/formatting** (title-casing, month/
  day/decade token builders, `GeneratedTags` emit order), and the new `RootMarker`/`DurableLink` types.
- **Reader and Processor migrate ONTO ArchiveCore in W0**, deleting their now-duplicated copies. This is a
  **behavior-preserving refactor** — parity (identical build + green tests + green smokes) is the acceptance
  bar, not new behavior. Staged so every sub-task leaves *all* apps building + green.
- **Both apps write tags through ONE audited seam.** ArchiveCore owns the coordinated metadata-only write
  primitive (NSFileCoordinator + trustworthy-read guard + lossless delta + verify-by-re-read); Reader's
  delta-mutate and Processor's fresh-write are thin adapters over it. Archive Notes' `NotesTagProjector` (§9)
  is a third thin adapter over the same primitive — so there is exactly one place that can ever touch
  irreplaceable tag metadata.
- **Archive Notes (W1+) then depends on the already-built, battle-tested ArchiveCore** — no third parser,
  no third writer.
- **Tier-2 throughout** (touches `TagWriter` + both shipping apps + the shared SPEC). W0's write-path moves
  (S3/S4 in `00a`) get adversarial review + scratch-corpus functional tests. See `00a` for the full staging,
  rollback, and parity strategy.

> Still deferred to the *later* convergence follow-on (NOT part of W0): the unified suite-wide storage path
> (§2, §15). W0 unifies the *code*; that item changes behavior/data and stays separately gated.

---

## 11. Fast index & scale (100k notes / 2M words)

A `NotesIndex` SQLite **FTS5** store, forked directly from Reader's proven `ContentIndex`/`ContentIndexer`
(actor-confined `import SQLite3`, WAL + `synchronous=NORMAL`, 500-row batched upserts, mtime-skip incremental
build via `withTaskGroup` at `cores-2`, bm25 ranking, gated pruning, `wal_checkpoint(TRUNCATE)` maintenance).
Differences for Notes (`02`):
- Columns/weights tuned for prose: `title` (10) · `tags` (6) · `authors` (4) · `body` (1) · linked-doc
  display names (3). bm25 relevance sort as the default while a query is active.
- The index also carries the **organizational graph** (folders, memberships, template assignments) as normal
  tables (NOT FTS) so the 3-pane tree, replication, and scoped queries are all DB-driven and fast at 100k.
- **Authoritative-data caveat**: note *body/front-matter* is authoritative in the files; the FTS mirror is
  disposable. But memberships/folders are app-owned — persisted in the DB **and** exported to
  `organization.json` on every change (atomic write) so they survive a DB wipe and a computer move.
- As-you-type search: 150 ms debounce + generation-token coalescing + auto-`.relevance` sort, reused from
  Reader's `NavigationModel` search UX.

---

## 12. Risk, tiers & the Prime Directives (inherited)

- **File safety > everything.** Never write to a real corpus. Notes writes only its **own** store; the only
  corpus interaction is **read-only** (durable-link resolution, page rendering, Copy-link consumption). All
  dev/test tag writes happen on **scratch copies** (`mktemp`), never the owner's data (memory
  `archive-test-run-safety`; Reader Prime Directive).
- **Tier-2** (adversarial review + a functional test on scratch copies) for: the `NotesTagProjector` (§9),
  the front-matter/organization atomic writers + delete-last-instance path (§3.6, `02`), and the Reader
  deep-link/reveal + Copy-link path (`04`). **Tier-1** for pure UI/editor/index
  work with no irreplaceable-data surface, but always: clean build, **no new warnings**, unit tests, and GUI
  verification where feasible.
- **Shared-contract change** (`SPEC/tag-format.md` + ArchiveCore) is the coordinated, atomic risk — see `01`.
- **Bounded chunk per session**, verified + committed + pushed + checkbox flipped, then stop (autonomous loop).

---

## 13. Wave index (→ bounded autonomous sessions) — ALL SHIPPED (record only)

**Every wave below shipped (W0–W8) and its plan file was deleted** (git history keeps them). The table is kept
as an at-a-glance record of what the app is; for current truth read the code + [`ArchiveNotes/CLAUDE.md`](../../ArchiveNotes/CLAUDE.md)
and the W0–W8 `[x]` records in [`SUITE_TODO.md`](../../SUITE_TODO.md). The **`(later)`** row is the one open,
separately-gated follow-on. "Tier" per §12.

| Wave | Plan | Goal | Depends on | Tier |
|------|------|------|-----------|------|
| **W0** | `00a` | **ArchiveCore extraction + suite-wide migration — DONE FIRST.** Create `packages/ArchiveCore`; move the shared tag/PDF/date contract (facet parser + `sortDate` + read + the audited **write** path + Processor vocabulary/formatting + `PDFTextExtractor`/`PDFFormatStatus` + new `RootMarker`/`DurableLink`) out of Reader & Processor; migrate **both shipping apps** onto it. Behavior-preserving, parity-gated, one audited write seam. | — | **Tier-2** (TagWriter + both shipping apps + SPEC) |
| **W1** | `01` | Third-app scaffold (`ArchiveNotes/`, project.yml, entitlements, launch/bootstrap/test-smoke, root dispatcher, DMG entry, AGENTS/CLAUDE), app skeleton + empty 3-pane shell that builds & launches, **depending on the W0 ArchiveCore** | W0 | Tier-2 (scaffold) |
| **W2** | `02` | Note/extract **store** (UUID folders, front-matter I/O, atomic saves, `NotesTagProjector`), **virtual folders + replication** model + `organization.json`, **SQLite FTS5 index** + incremental build | W1 | Tier-2 (writers) |
| **W3** | `03` | **Rich-text/Markdown editor** (NSTextView/TextKit, attributed↔Markdown bridge, formatting toolbar, inline images + paste, raw-Markdown toggle, block rendering) | W1 (W2 for persistence) | Tier-1 |
| **W4** | `04` | **Source blocks + cross-app linking**: page-thumbnail render+cache; Reader URL scheme + router + `revealAndSelect`; **Copy Archive Link(s)** + pasteboard payload; Notes paste-to-blocks; `archivenotes://` scheme; durable-link resolution | W1, W2 | Tier-2 (Reader deep-link) |
| **W5** | `05` | **Zotero** metadata integration (local API/Better BibTeX detect+fetch, item/attachment select links, citation, chips, degrade gracefully) | W2, W3 | Tier-1 |
| **W6** | `06` | **Viewers**: note & extract 3-pane windows, folder-tree sidebar (mutable), item list, search+filter(kind/tag/keyword)+date-sort, replication UI + delete-last-instance guard, templates (folder-assigned), dates & quality UI | W2, W3 | Tier-2 (delete path) |
| **W7** | `07` | **Extracts**: Create-Extract (snapshot+provenance), extract blocks→notes, jump-to-source, extract-viewer featuring | W2, W3, W6 | Tier-1 |
| **W8** | `08` | **Tests & GUI verification**: unit suites (front-matter, md-bridge, projector safety, index, folders/replication, links), XCUITest+cliclick GUI harness, smoke gate, end-to-end scratch-corpus run | W1–W7 | Tier-1 |
| **(later)** | — | **Behavior/data follow-on** (NOT W0, which unifies only the *code*): unified suite storage path | W0–W8 | Tier-2, separately gated |

Estimated bounded sub-tasks per wave are enumerated in each plan file; expect ~3–6 sessions per wave.

---

## 14. Definition of done (per §"How we work" + Docs convention)

Every wave sub-task: own worktree → clean build, no new warnings → touched-app smoke/unit tests → Tier-2
review where §12 requires → **docs move in the same commit** (flip the `SUITE_TODO.md` Archive Notes
checkbox, update this folder's plan/`KNOWN_ISSUES.md`) → push → remove worktree. Delete a wave plan file only
when its wave fully ships (git keeps history); keep `00-overview.md` until the whole app ships, then fold the
durable architecture into `ArchiveNotes/CLAUDE.md`.

---

## 15. Open questions carried to future iterations (non-blocking)

1. **Unified storage path** for Processor+Reader+Notes (the owner's "move to a new computer easily" goal) —
   design a suite-level default root + a migration that re-keys Reader's path-keyed index/NotesStore.
2. **ArchiveCore write-path shape** — W0 (`00a`) puts one audited coordinated-write primitive in ArchiveCore
   with thin per-app adapters (Reader delta-mutate, Processor fresh-write, Notes projector); revisit only if
   a fuller single unified-writer API is later wanted.
3. Whether Notes and Reader should ever share **one window / unified view** (currently separate apps).
4. Mirroring **author** into Finder tags for author faceting of notes. Date already projects the existing
   shared facets while remaining front-matter-authoritative; author would need a SPEC `Author:` facet
   (a shared-contract change; D2/D4).
5. Zotero: write-back (creating Zotero items from Notes) — read-only for now.
6. Scrivener specifics: confirm Scrivener honors custom URL schemes in its link fields (it does for
   standard hyperlinks; validate the `archivenotes://` round-trip on the owner's Scrivener during W4 GUI).

---

## 16. Interface Contract (authoritative shared types & cross-wave APIs)

> The wave plans (`01`–`08`) were drafted in parallel and occasionally sketch the same shared type or API
> with slightly different names/signatures. **This section is authoritative — where any wave differs, THIS
> wins.** Every implementation session must reconcile to the symbols below before writing code. (This
> section exists specifically to prevent the cross-session interface drift that breaks unattended builds.)

### 16.1 Persistence & UI ownership
- **`actor NoteStore`** — the ONLY file/asset persistence layer (async). Singular name, to avoid colliding
  with Reader's unrelated `NotesStore`. Canonical API (all `async throws` unless noted):
  - `create(_ item: Item, blocks: [Block]) -> Item`
  - `save(_ item: Item, blocks: [Block])`
  - `load(id: UUID) -> (Item, [Block])`
  - `rename(id: UUID, to title: String)` — renames `<uuid>/<Title>.md` (title=filename, D1)
  - `delete(id: UUID)` — deletes the whole `<uuid>/` folder; **only ever called after** the last-membership guard (§3.6)
  - `importAsset(_ data: Data, ext: String, into id: UUID) -> String` — writes into `<uuid>/assets/`, returns the `assets/<file>` relative path
  - `copyAssets(from: UUID, to: UUID, rewriteBodyPaths body: String) -> String` — Create-Extract asset carry-over; returns rewritten markdown
  - `metadata(for id: UUID) -> ItemMetadata?`
  - `allItemIDs() -> [UUID]`
- **`@MainActor final class NotesModel`** — the UI façade every view binds to; wraps `NoteStore` +
  `NotesIndex` + `OrganizationStore`, exposes `@Published` state and `async` edit methods (`setDate`,
  `setQuality`, `setTags`, `setTitle`, `commitBody`, …) that `await` the actor then update published state.
  W6's "synchronous field writers" are these async methods. **In-process navigation entry point:**
  `func openItem(id: UUID, block: Int?)` — selects+reveals the item in the correct window (BUILT in W6;
  CALLED by W4's URL router and W7's jump-to-source). This resolves the `NotesNavigation.openItem` gap.
- **`@MainActor final class OrganizationStore`** — owns the folder tree + memberships + template
  assignments; persists to the index DB **and** `organization.json` (atomic). Canonical methods:
  `addMembership(item:folder:)`, `removeMembership(item:folder:) -> RemoveResult` (`.removed` |
  `.wasLastInstance` so the caller triggers the §3.6 delete guard), `createFolder`, `renameFolder`,
  `moveFolder`, `deleteFolder`, `assignTemplate(folder:template:)`, `foldersContaining(item:)`,
  `extractsHomeFolderId`. (Supersedes the `FolderGraph` name used by a couple of waves.)

### 16.2 Durable links & root marker (live in ArchiveCore)
```swift
enum DurableLink: Equatable {
  case readerReveal(rootGUID: UUID, relativePath: String, page: Int?)   // archivereader://reveal?root=&rel=&page=
  case notesOpen(id: UUID, block: Int?)                                 // archivenotes://open?id=#block-<n>
}
struct RootMarker: Codable {          // .archive-suite-root.json (dropped at a granted root)
  let guid: UUID                      // serialized as a lowercased UUID string
  var name: String
  let kind: RootKind                  // .reader | .notes
  let createdAt: Date
}
```
Field label is **`block`** (not `blockIndex`) everywhere; `RootMarker.guid` is **`UUID`** (not `String`).

### 16.3 Filtering / smart folders — ONE type
```swift
struct NotesFilter: Codable, Equatable {   // BOTH live filtering AND smart-folder persistence (folders.query_json)
  var searchText: String = ""
  var tags: [String] = []
  var tagCombine: TagCombine = .all         // .all | .any
  var kind: KindFilter = .both              // .notes | .extracts | .both
  var qualities: Set<Int> = []              // empty = any
  var dateFrom: SortDate? = nil
  var dateTo: SortDate? = nil
  var folderId: UUID? = nil                 // scope (smart-folder-as-root)
}
```
Drop the reduced `SmartQuery`; a smart folder stores an encoded `NotesFilter` in `folders.query_json`.

### 16.4 Templates — assignments table only
No `folders.template_id` column and no `Folder.templateId` field. Template↔folder lives ONLY in
`template_assignments(folder_id, template_id)`; W6 resolves a folder's template by walking to the nearest
ancestor with an assignment.

### 16.5 Index `items` projection (so W6/W7 render lists WITHOUT reading `.md`)
The non-FTS `items` table and the `ItemSummary` it yields MUST carry every field any list/sort needs:
`id, title, kind, date, date_precision, date_uncertain, authors (JSON array), sort_date, quality, created,
modified, mtime, managed_tags`. `ItemSummary` exposes those (authors `[String]`, dates typed). This closes
the W6 gap (italic-on-`date_uncertain`, authors column, and `modified` sort are all index-served).

### 16.6 System folders (seeded on first launch by OrganizationStore)
`All Notes` (smart root), `Inbox` (normal; default membership for a new note with no chosen folder), and
`Extracts` (`extractsHomeFolderId`; default membership for new extracts). Satisfies W7's `extractsHomeFolderId`.

### 16.7 PDFThumbnailer placement
`PDFThumbnailer` (PDFKit page→image + two-tier cache, W4) lives in the **ArchiveNotes app target**, NOT
ArchiveCore — Reader renders pages live and never needs it, so ArchiveCore stays minimal/read-side.

### 16.8 archivenotes:// grammar (canonical)
`archivenotes://open?id=<UUID>` with optional `#block-<n>`. §6's block-header `note:` example uses this exact
form; any `archivenotes://note/uuid` phrasing is superseded.

### 16.9 Concurrency posture (Swift 6)
`NoteStore` and `NotesIndex` are `actor`s (off-main I/O). Everything UI-facing is `@MainActor`
(`NotesModel`, `OrganizationStore`, views). Cross-actor payloads (`Item`, `Block`, `ItemSummary`,
`DurableLink`, `RootMarker`, `NotesFilter`) are `Sendable` value types. No shared mutable state crosses an
actor boundary except through these value types.
