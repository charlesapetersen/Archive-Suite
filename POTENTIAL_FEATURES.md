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
