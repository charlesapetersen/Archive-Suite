# Potential Features

Forward-looking backlog for **Archive Notes**. The core roadmap + shipped state live in
[`CLAUDE.md`](CLAUDE.md); near-term work lives in the root [`SUITE_TODO.md`](../SUITE_TODO.md). This file is
the durable *wishlist* tier — long-term, deliberately-deferred design directions. Seeded 2026-07-18 from the
Notes execution plans (`execution-plans/archive-notes/{00-overview,09-gap-closure}.md`), `KNOWN_ISSUES.md`
deferred tails, and `CLAUDE.md` owner-decision notes. Several items overlap the sibling apps' backlogs —
evidence these are one suite.

> **Not here on purpose.** Near-term Notes work is tracked elsewhere and is **not** repeated below — cross-reference,
> don't duplicate: the **DEVONthink import** (`SUITE_TODO.md` → *Archive Notes — DEVONthink import* + the active
> `execution-plans/devonthink-import.md`; carries the net-new multi-date / Related-notes / 5★→3★ features), the
> **Reader/Notes PDF+JPEG dual image reference** (same SUITE_TODO section), the **W9 gap-closure** phases
> (built-but-dead wiring / safety-net tooling / UI polish — near-term gaps, not wishlist), **W15.tu3** (the
> `CoordinatedTagWriter` per-path write serialization), and the **§16 Interface-Contract doc-fold** (SUITE_TODO
> *Suite doc hygiene*). R13d removed the old ArchiveSuite-marker "convergence" deferrals from
> `00-overview.md`; do **not** resurrect them here.

## Medium priority

- **Mirror author/date/quality to Finder tags for cross-app parity** — today Notes keeps `authors`/`date`/`quality`
  **front-matter-only** (overview decisions D2/D4/D9); the projector writes only subjects.
  Additionally mirroring author/date/quality into macOS Finder tags would let Reader/Processor sort/browse Notes
  items chronologically and by author like corpus files. **A deferred OWNER DECISION** (flagged to Morning
  Review): it needs a shared-contract `Author:` facet in `SPEC/tag-format.md`, so it is **Tier-2** and touches all
  three apps. This is the standout cross-app-parity item. _(CLAUDE.md Core-Directive bullet; 00-overview §15.4.)_
- **Unified suite-wide storage path + migration** — a suite-level default root plus a migration that re-keys
  Reader's path-keyed index and the Notes store, serving the owner's "move to a new computer easily" goal.
  Tier-2, separately gated. _(00-overview §15.1 / §2 deferred list; also noted in `SUITE_TODO.md` as a `(later)`
  behavior/data follow-on.)_
- **Zotero write-back** — Notes currently only *reads* Zotero metadata (D8, read-only client). A future iteration
  could create/update Zotero items from Notes. _(00-overview §15.5; 09-gap-closure out-of-scope.)_
- **Extract re-snapshot / refresh from source** — extracts are snapshot+link (D7), so source edits deliberately
  don't touch them; an opt-in affordance could re-pull the latest source-note text into an existing extract on
  demand. _(09-gap-closure out-of-scope.)_
- **Multi-root Reader corpus support** — durable-link resolution currently resolves against a single granted
  Reader root; supporting multiple corpus roots is deferred. _(00-overview §2 deferred list; 09-gap-closure.)_
- **Notes + Reader unified window / shared view** — an open architectural question of whether Notes and Reader
  should ever share one window (or a unified view) rather than remaining separate apps. _(00-overview §15.3.)_
- **Source/passage chip buttons XCUITest-hittable (accessibility)** — the TextKit-2 attachment-view chip buttons
  (`an.chip.{jump,reveal,preview,zoteroOpen}`) are not in the accessibility tree; making them hittable would also
  help VoiceOver. May not be possible for TextKit-2 attachment subviews. _(KNOWN_ISSUES W8-S8 pass 6.)_

## Lower priority / long-term

- **Richer Markdown editor** — tables, footnotes, task-lists, strikethrough, inline HTML, and preserving undo
  history across the raw/styled toggle, beyond the shipped construct set. _(09-gap-closure out-of-scope.)_
- **Per-block stable GUIDs + reverse back-index** — give blocks durable per-block identity and build the inverse
  "N extracts derive from this note" index for a source note. _(09-gap-closure out-of-scope.)_
- **Author inheritance** — auto-populate an extract's author from its source note instead of manual entry.
  _(09-gap-closure out-of-scope.)_
- **`zotero://open-pdf` page-anchored links** — support page-anchored attachment links in addition to
  `zotero://select` item/attachment links. _(09-gap-closure out-of-scope.)_
- **Page-within-merged-PDF scroll navigation** — from the source-block quick preview, scroll to a specific page
  inside a merged/multi-doc PDF. _(09-gap-closure addendum.)_
- **Front-matter whitespace-normalization tightening** — tighten `FrontMatterCodec.needsQuoting` so leading/
  trailing non-U+0020 whitespace (tab / NBSP) in a scalar survives a round-trip instead of being normalized away
  (marginal — regular edge-spaces already survive). _(KNOWN_ISSUES W8-S1.)_
- **Unify the page-2 (OCR) PDF header *builder* across apps** — W0 unified the reader/parser side of the 2-page
  PDF header; the *builder* is still per-app. Shared-code dedup. _(09-gap-closure out-of-scope.)_
