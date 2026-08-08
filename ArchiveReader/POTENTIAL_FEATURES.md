# Potential Features

Forward-looking backlog. Core roadmap lives in [CLAUDE.md](CLAUDE.md); this is the
wishlist beyond it. Several items overlap Archive Processor's own backlog — evidence these apps are
one suite.

## High priority — SHIPPED in v1 (2026-07-05) ✅
All High-priority items are implemented (see `CLAUDE.md` §Implementation map):
- ✅ **Document-run / provenance convenience** — opt-in "Select Document Run" via the content index's
  classification (degrades to a single item when absent; never auto-groups). *Residual:* a dedicated
  Box/Folder provenance breadcrumb column is not yet surfaced.
- ✅ **Reading-session resume** — the selection is persisted (≤500) and restored on next launch.
- ✅ **App-side notes / flags OUTSIDE the corpus** — `NotesStore` (UserDefaults); flag column + editor.
- ✅ **Corpus data-quality dashboard** — the library-health popover (stethoscope in the status bar).
- ✅ **Quick Look preview** from the nav list (⌘Y — moved off bare Space so it can't block typing).
- ✅ **Saved searches / smart folders** — `SavedSearch` + the toolbar "Saved" menu.
- ◑ **Non-sandboxed whole-Mac search** — **no longer code-ready; re-costed 2026-08-07 (`W26.docs`).** This
  bullet used to say it was a build-time entitlement flip (drop `com.apple.security.app-sandbox`) because
  `ArchiveLibrary.start(scope: nil)` fell through to Spotlight's local-computer scope. `W26.walk2` deleted
  that branch: `nil` now *clears* the library, and discovery is a `CorpusWalker` walk of one granted root.
  Whole-Mac would mean **new code** — walking N roots, merging their results, and a defensible answer for
  what "the whole Mac" excludes (an unbounded `/` walk is not it). Still kept sandboxed by owner decision.


## P2 — SHIPPED (2026-07-07) ✅
The P2 triage pass shipped (see `CLAUDE.md` §Implementation map):
- ✅ **Non-standard / non-conforming PDF handling** — read-only detection (`PDFFormatStatus`: standard /
  unreadable / no-text-layer; **page count is never a defect signal**) drives the per-row ⚠︎ badge, the
  library-health counts, a "Needs attention" filter, and a viewer banner naming what's missing.
- ✅ **Near-duplicate subject-tag detection** (`TagSimilarity`) — Find Similar Tags clusters typos
  (`Environment` vs `Environtment`) and offers a merge (via the corpus-wide tag rename).
- ✅ **Duplicate-filename disambiguation** (`DuplicateNames`) — colliding rows show their containing
  folder; copied link groups carry full paths.
- ✗ **Side-by-side compare of two documents** — **dropped** (superseded by multi-select + ↑/↓ cycling).

## Medium priority
- **Controlled subject vocabulary (optional)** — restrict subject tags to an allowed list (near-duplicate
  detection via `TagSimilarity` and corpus-wide bulk rename already shipped).
- **Fuzzy OCR text search** — tolerate typos / near-matches in full-text search (FTS5 prefix/`NEAR`,
  a trigram tokenizer, or an edit-distance layer over candidates), so a misspelled query still finds
  the document. Deferred by owner (2026-07-09); would coordinate with the bm25 ranking in the
  `index-parallelization` plan. | Search/ContentIndex.swift, Views/NavigationModel.swift.

## Lower priority / long-term
- **Cloud-drive support** (Google Drive / File Provider): conflict-copy handling, materialization
  policy, cloud-side tag-durability verification. (v1 assumes local disk.)
- **Creation-date mirror** for native Finder chronological browsing (1678–2262 only; a bonus, never
  the sort key).
- Zotero / Tropy integration. _(IIIF manifest / EAD / Dublin Core export removed 2026-07-15 — owner: out of scope.)_

## Archive Suite convergence — ✅ SHIPPED (W0, 2026-07)
- ✅ **Shared `ArchiveCore` Swift package** — the UI-free tag/PDF model AND the unified audited writer both
  shipped in the W0 refactor: `packages/ArchiveCore/` holds the read model (`DocumentTags`, `PDFFormatStatus`,
  `TagSimilarity`, `DuplicateNames`, `FileLink`, `CopyTextCleaner`, links/thumbnails) plus `Tags/TagWrite.swift`'s
  `CoordinatedTagWriter` (trustworthy-read guard + verify-by-re-read); both apps delegate to it, so the
  safety-critical tag code can no longer drift.
- ✅ **Monorepo** — `Archive Suite/` now houses `ArchiveProcessor/`, `ArchiveReader/`, `ArchiveNotes/`,
  `packages/ArchiveCore/`, a shared `launch.sh`, and `suite-v*` release tags. See [CLAUDE.md](CLAUDE.md) → Archive Suite.
