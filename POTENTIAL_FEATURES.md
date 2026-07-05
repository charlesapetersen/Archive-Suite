# Potential Features

Forward-looking backlog. Core roadmap lives in [PLAN.md](PLAN.md) (§Milestones); this is the
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


## Non-standard / non-conforming PDFs (deferred from the 2026-07-05 near-term UI list)
"Standard" = a 2-page PDF (page 1 image + page 2 OCR text), ideally with a `Classification:` line.
Non-standard = 1-page / >2-page / 0-page / corrupt / encrypted / non-PDF image / no OCR-text layer /
no classification. The viewer + indexer already **degrade gracefully**; this work is about
**visibility + triage** (no corpus writes — detection reuses `PDFTextExtractor` / `ContentIndexer`,
which already know page count, text presence, and the classification):
- **[S]** Library-Health popover: add counts — non-2-page, no OCR-text layer, unreadable/corrupt, non-PDF.
- **[S]** A "Non-standard format" filter chip and/or a built-in **"Needs attention"** smart folder.
- **[S]** A subtle per-row ⚠︎ badge in the list for flagged files.
- **[M]** A viewer banner on a non-standard doc stating what's missing ("1 page · no OCR text layer").

## Medium priority
- **Side-by-side compare** of two selected documents (beyond ↑/↓ cycling) — collate a photo spanning
  two frames, or compare versions.
- **Duplicate-filename disambiguation** — surface containing folder/box for same-named files.
- **Tag vocabulary tools** — near-duplicate detection (`Environment` vs corpus typo `Environtment`),
  optional controlled vocabulary, bulk rename of a subject tag across the corpus (via `TagWriter`).

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
