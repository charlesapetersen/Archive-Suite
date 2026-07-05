# Archive Reader — Implementation Plan

Durable plan of record. Companion to `CLAUDE.md` (which holds the Core Directive, Verified Facts,
and Safety Protocol). This file: decisions, milestones, keyboard map, options, edge-case rules,
feature backlog. Built from a 5-proposal design workflow + adversarial critique + a completeness
audit + empirical tests on the real corpus (2026-07-04).

---

## §Decisions — needs owner review (⚠ = awaiting answer)

**Settled / recommended (owner can override):**
- **Chronological sort key = derived from tags** (universal, medieval-safe, no Processor change).
  Creation-date native sort is a deferred bonus. → CLAUDE.md.
- **Date Uncertain** → sorts by its (speculative) year; displayed in *italics*.
- **Discovery = Spotlight** (`NSMetadataQuery`) over user-granted **archive root(s)**; master
  universe = files tagged `Read` or `Unread`. No SQLite/ORM dependency.
- **Subject filters combine with AND** by default (matches the "Cold War AND Unread AND P10"
  workflow); OR and NOT available as an explicit toggle.
- **Read-state = tri-state filter** (Read / Unread / No-read-state). "Mark Read" never *adds* a
  read-state token to a marker/neither file by default (option, off).
- **Facet classification is display/sort/filter only** — never drives a write. Numeric/`P#`/`Read`
  subject collisions resolved by co-occurrence heuristics + user display-only correction.
- **Tables/viewer degrade** for non-2-page, non-PDF, corrupt files — never crash.
- **Full tag editing is a first-class feature** (single file *and* group), via `TagWriter` — not
  just Read/Unread. Facet-aware editors (date, priority, color) + free-form subject tags with
  autocomplete from existing corpus tags; near-duplicate warning (e.g. `Environment` vs the corpus
  typo `Environtment`) to curb fragmentation. Editing changes tags only — never bytes or location.

**Resolved with owner (2026-07-04):**
1. **Reading/grouping = user-driven manual multi-selection (definitive).** The user decides which
   consecutive PDFs open & cycle together; the app **never auto-groups**. Segment/classification
   awareness (`Document Start`/`Continuation` — *not always present*) is only an optional, opt-in
   convenience that silently degrades to plain selection. Markers give higher-level provenance.
2. **Full-text OCR search is in v1**, via the app's **content index** (not dependent on Spotlight
   content indexing), plus in-document ⌘F.
3. **Sandbox posture: v1 sandboxed**, scoped to the provided test-files folder (security-scoped
   bookmark). **Non-sandboxed whole-Mac search planned long-term** → file access behind a
   `FileAccessProvider` abstraction so the switch is config, not a rewrite.

---

## §Milestones (interruption-resilient; each ends buildable + committed)

**M0 — Skeleton + safety core** *(do first; nothing else ships without it)*
- XcodeGen `project.yml`, two empty SwiftUI windows, build clean.
- `TagWriter` (delta-based; handles all tag edits and the Read/Unread preset) implementing the full
  Safety Protocol (CLAUDE.md).
- Test suite on **scratch copies**: color round-trip, read-failure-guard (no wipe), subject
  collision refusal, arbitrary add/remove-delta correctness, inverse-delta undo, multiset + bytes
  invariant, group tri-state edit, non-2-page guard, write-surface lint. Tier-2 adversarial review.

**M1 — Navigation vertical slice** *(the product's core)*
- `NSMetadataQuery` discovery scoped to a granted root; live updates.
- Table: columns (Document date · File name · File type · File tags · Read/Unread); date derived
  from tags (Year/Month/`Day N`) → sortable key; Date-Uncertain italic; multi-level sort
  (chronological → filename default); Archive-order sort mode.
- Three filters: subject (AND/OR/NOT), priority (P7–P10), read-state (tri-state).
- Copy file links for single & multi-selection (⌘⇧C), correct percent-encoding (em dash, NBSP).
- Mark Read/Unread (fast-path preset of `TagWriter`); verified rows drop from an Unread view;
  grouped undo; partial-failure sheet. **Perf-test the table at ~150k early** (abstract the data
  layer so an AppKit `NSTableView` swap is possible if `Table` janks).
- **Tag editor (single + group):** an inspector panel (keyboard-driven, à la Archive Processor's
  token field) to add/remove subject tags, set date facets (Year/`MM Month`/`Day N` + Date
  Uncertain), set priority (P7–P10), and set/clear color (box/folder); autocomplete + near-duplicate
  warning from the live corpus tag set. Group edits show Finder-style tri-state (all/some/none).
  All writes go through `TagWriter` (delta + verify + grouped undo).

**M1.5 — Content index (background)**
- `libsqlite3` FTS5 index (no third-party dep). Background extractor reads each PDF's page-2 text
  once → caches OCR body + (when present) `Classification:` + header metadata; incremental for
  new/changed files; progress UI; fully rebuildable/disposable. Primary purpose: **full-text
  search**; classification is captured opportunistically for optional provenance/convenience only.
- **Corpus-wide full-text search** in the nav window (query the FTS index; snippets + ranking),
  combinable with the tag facet filters.

**M2 — Document view window + segment-aware reading**
- Two `PDFView`s (image left / OCR text right); independent per-pane zoom; draggable gray splitter
  w/ center grab handle; **default 2/3 : 1/3** re-applied per document.
- Up/Down cycles the selected set (lazy-load, don't materialize all).
- **User-driven grouping is definitive:** the user multi-selects which files open & cycle together;
  the app **never auto-groups**. *Optional, opt-in convenience only* (degrades silently when the
  classification is absent): an "extend selection to next Document Start" command + marker/section hints.
- Intelligent copy in either pane (single-newline→space, blank-line paragraph, de-hyphenate);
  optional "skip OCR header". In-doc Find (⌘F). Graceful degrade for non-2-page/corrupt.
- Mark Read + advance from the viewer.

**M3 — Options panel + polish**
- Options (⌘,) — see §Options. Finalized collision-free keyboard map (see §Keyboard).
- Accessibility: honor Reduce Motion (instant row removal), VoiceOver announcements
  ("12 marked Read, removed"), deterministic post-removal focus.
- Corpus data-quality view: counts of no-date / no-priority / Date-Uncertain / both-Read+Unread
  (corruption) / unreadable.

**M4 — Power features** (as prioritized)
- Full-text OCR search (if not in v1); document-run grouping + per-box progress + "mark whole box
  Read"; box/folder provenance column; reading-session resume; export/citation (CSV / Markdown /
  finding-aid); app-side notes/flags stored **outside** the corpus.

**§Future / deferred**
- Cloud-drive (Google Drive / File Provider) support: conflict-copy handling, materialization
  policy, cloud-side tag durability verification.
- Optional creation-date mirror for native Finder chronological browsing (1678–2262 only).
- IIIF / EAD exports; side-by-side document compare; Quick Look preview.
- **Archive Suite convergence** (see `CLAUDE.md` §Archive Suite): at ~M3 extract the UI-free `Core/`
  into an `ArchiveCore` Swift package shared with Archive Processor, then a monorepo + shared version
  tag. Until then the tag/PDF contract is the coupling and is kept identical in both repos.

---

## §Keyboard map (collision-free — filenames start with digits; type-select uses bare keys)

*Navigation window*
- `↑`/`↓` move selection · `⇧↑/⇧↓` extend · `⌘A` select all · type letters/digits = type-select
- `⏎` or `⌘O` open selection in document window · `Space` = Quick Look preview
- `⌘R` mark Read (+ advance) · `⌘U` mark Unread · `⌘I` open tag editor for the selection ·
  `⌘Z`/`⇧⌘Z` undo/redo tag change (grouped)
- `⌘⇧C` copy file link(s) · `⌥⌘⇧C` copy plain path(s)
- `⌘F` focus filter bar · `⌘1..⌘4` toggle priority P10..P7 · `⌃⌘R` cycle read-state filter

*Document window*
- `↑`/`↓` previous/next document in the selected set · `⌘←/⌘→` first/last
- `⌘=`/`⌘-` zoom focused pane · `⌥⌘=` reset both panes to default · `⌘F` find in OCR text
- `⌘C` intelligent copy · `⌘⇧C` copy this file's link · `⌘R` mark Read + advance
- `⌘,` options (both windows)

---

## §Options panel (⌘,)

- **Link format:** `file://` URL · POSIX path · Markdown `[name](url)` · HTML `<a>` (default `file://`).
- **Newlines after each link:** integer (default per taste). Include filename in link line? y/n.
- **Copy text:** de-hyphenate line-end hyphens (on) · collapse single newlines→space (on) ·
  blank line = paragraph break (on) · skip OCR-page header block (off).
- **Viewer:** default split ratio (0.667) · default per-pane zoom / fit mode · reset-per-document (on).
- **List:** date display format · default sort levels · subject-combine AND/OR default ·
  read-state default filter · show Box/Folder provenance column.
- **Tag editing:** warn on near-duplicate subject tags (on) · optional controlled vocabulary
  (restrict new subjects to existing corpus tags) · confirm-before-write threshold for large group
  edits (e.g. > N files).
- **Accessibility:** honor Reduce Motion (system) · animation speed.
- **Archive roots:** add/remove root folder(s) (security-scoped bookmarks).

---

## §Edge-case rules (from the completeness audit)

- **Not exactly 2 pages / non-PDF / corrupt/encrypted:** probe page count + UTType; single-pane or
  "no OCR page" state; guard `PDFDocument(url:)==nil`. Tagged non-PDF images (possible markers) are
  *included* in results (they carry read-state) but the viewer degrades.
- **Neither Read nor Unread:** tri-state "No-read-state" bucket; markers visible, never silently lost.
- **Read-failure ≠ empty tags:** abort the write (Safety Protocol §3).
- **Duplicate filenames across boxes:** show containing folder as secondary column / row subtitle;
  copied link groups carry full paths.
- **Unicode:** normalize (NBSP→space, dash-fold, case/diacritic-fold) for search/type-ahead/sort
  keys **only**; preserve real bytes for display + link encoding.
- **Multiple same-facet date tags** (two Years/Months): deterministic rule (earliest) + flag ambiguous.
- **Facet-looking subjects** (`1984`, `P7`, `Read`): heuristics + display-only user correction;
  never affects writes.

---

## §Feature backlog (nice-to-have, from the audit)
Full-text OCR search · in-doc Find · Copy-citation (date + box provenance + path) · export filtered
set · box/folder provenance breadcrumb · Archive-order sort · mark-whole-box Read + progress ·
reading-session resume · app-side notes/flags outside corpus · data-quality dashboard · Quick Look ·
side-by-side compare.
