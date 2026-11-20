# Potential Features

Forward-looking backlog for **Archive Notes**. The core roadmap + shipped state live in
[`CLAUDE.md`](CLAUDE.md); near-term work lives in the root [`SUITE_TODO.md`](../SUITE_TODO.md). This file is
the durable *wishlist* tier — long-term, deliberately-deferred design directions. Seeded 2026-07-18 from the
Notes execution plans (`execution-plans/archive-notes/00-overview.md` and the since-deleted `09-gap-closure.md`), `KNOWN_ISSUES.md`
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

- **Unified suite-wide storage path + migration** — a suite-level default root plus a migration that re-keys
  Reader's path-keyed index and the Notes store, serving the owner's "move to a new computer easily" goal.
  Tier-2, separately gated. _(00-overview §15.1 / §2 deferred list; also noted in `SUITE_TODO.md` as a `(later)`
  behavior/data follow-on.)_ Moved into the survey `W49.storage-simplify-audit` (owner, 2026-11-20, call 27; the 2026-11-19 fold into
  `W49.notes-store-format` was the session's, not his). The survey (`execution-plans/storage-simplify.md` §6) found it simpler under the proposed homes: the build it needs is W49.reader-root-movable; a shared default location stays here as a wish.
- **Zotero write-back** — Notes currently only *reads* Zotero metadata (D8, read-only client). A future iteration
  could create/update Zotero items from Notes. _(00-overview §15.5, §17 out-of-scope.)_
- **Extract re-snapshot / refresh from source** — declined (owner, 2026-11-20, call 27): extracts stay snapshots. Was: extracts are snapshot+link (D7), so source edits deliberately
  don't touch them; an opt-in affordance could re-pull the latest source-note text into an existing extract on
  demand. _(`00-overview` §17 out-of-scope.)_
- **Multi-root Reader corpus support** — Notes' durable-link resolution already handles several granted Reader
  roots (`ReaderRootStore`, keyed by root marker GUID; corrected by W49.storage-simplify-audit, 2026-11-20); the
  Reader app itself still shows one root, and walking several there is deferred. _(00-overview §2 deferred list, §17.)_ (queued: part of
  W49.storage-simplify-audit, owner 2026-11-20)
- **Notes + Reader unified window / shared view** — declined (owner, 2026-11-20, call 27): they stay separate apps,
  linked by source blocks. Was: an open architectural question of whether Notes and Reader
  should ever share one window (or a unified view) rather than remaining separate apps. _(00-overview §15.3.)_

## Lower priority / long-term

- **Richer Markdown editor** — tables, footnotes, task-lists, strikethrough and inline HTML, beyond the shipped
  construct set. _(`00-overview` §17 out-of-scope.)_ (queued: W49.notes-editor-constructs behind nice-to-have,
  owner 2026-11-20; undo across the raw/styled toggle shipped as W49.notes-undo-across-toggle)
- **Per-block stable GUIDs + reverse back-index** — queued: W49.notes-block-ids behind nice-to-have (owner, 2026-11-20, call 28) — give blocks durable per-block identity and build the inverse
  "N extracts derive from this note" index for a source note. _(`00-overview` §17 out-of-scope.)_
- **`zotero://open-pdf` page-anchored links** — queued: W49.notes-zotero-page-links (owner, 2026-11-20, call 28) — support page-anchored attachment links in addition to
  `zotero://select` item/attachment links. _(`00-overview` §17 out-of-scope.)_
- **Page-within-merged-PDF scroll navigation** — queued: W49.notes-preview-scroll behind nice-to-have (owner, 2026-11-20, call 28) — from the source-block quick preview, scroll to a specific page
  inside a merged/multi-doc PDF. _(`00-overview` §17 out-of-scope.)_
- **Unify the page-2 (OCR) PDF header *builder* across apps** — closed (owner, 2026-11-20, call 28): only the Processor builds that header. — W0 unified the reader/parser side of the 2-page
  PDF header; the *builder* is still per-app. Shared-code dedup. _(`00-overview` §17 out-of-scope.)_
