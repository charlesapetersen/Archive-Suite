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
- ◑ **Non-sandboxed whole-Mac search** — code-ready: `ArchiveLibrary.start(scope: nil)` uses the
  local-computer scope, so this is a build-time entitlement flip (drop `com.apple.security.app-sandbox`),
  not new code. Kept sandboxed for v1 by owner decision.


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
- **Full-text search snippet previews** — show a `snippet()`-style keyword-in-context excerpt for each
  hit (the matched OCR text with the query term highlighted), so results are scannable without opening
  each doc. Deferred out of the `index-parallelization` plan, which ships bm25 *relevance ranking* but
  **not** previews (owner, 2026-07-09). Depends on the content index already storing the OCR `body`
  (it does), so this is a search-UI addition, not an indexing change.
- **Fuzzy OCR text search** — tolerate typos / near-matches in full-text search (FTS5 prefix/`NEAR`,
  a trigram tokenizer, or an edit-distance layer over candidates), so a misspelled query still finds
  the document. Deferred by owner (2026-07-09); would coordinate with the bm25 ranking in the
  `index-parallelization` plan. | Search/ContentIndex.swift, Views/NavigationModel.swift.

## Lower priority / long-term
- **Cloud-drive support** (Google Drive / File Provider): conflict-copy handling, materialization
  policy, cloud-side tag-durability verification. (v1 assumes local disk.)
- **Creation-date mirror** for native Finder chronological browsing (1678–2262 only; a bonus, never
  the sort key).
- **IIIF manifest / EAD / Dublin Core export**; Zotero / Tropy integration.

## Archive Suite convergence
- Extract the UI-free `Core/` into a shared **`ArchiveCore`** Swift package used by both apps
  (unifies the safety-critical tag code so Processor and Reader can never drift).
- Monorepo (`Archive Suite/`) with a shared `bootstrap.sh` and version tag; distribute as two apps or
  one app with Process/Read modes. See [CLAUDE.md](CLAUDE.md) → Archive Suite.
