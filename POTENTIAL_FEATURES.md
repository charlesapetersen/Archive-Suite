# Potential Features

Forward-looking backlog. Core roadmap lives in [PLAN.md](PLAN.md) (§Milestones); this is the
wishlist beyond it. Several items overlap Archive Processor's own backlog — evidence these apps are
one suite.

## High priority (post-core)
- **Document-run / provenance convenience** — opt-in "extend selection to next Document Start" and a
  Box/Folder provenance breadcrumb, driven by the content index (degrades when classification absent;
  never auto-groups — the user always decides what opens together).
- **Reading-session resume** — "continue where I left off".
- **App-side notes / flags stored OUTSIDE the corpus** — bookmark or annotate documents without ever
  writing to the files.
- **Corpus data-quality dashboard** — counts of no-date / no-priority / Date-Uncertain /
  both-Read+Unread (corruption) / unreadable-or-offline files. Turns the reader into a health check.
- **Quick Look preview** from the nav list (space bar) without opening the full document window.
- **Saved searches / smart folders** — persist a filter+search combination.
- **Non-sandboxed whole-Mac search** (v1 is sandboxed to a granted root; access is behind
  `FileAccessProvider` so this is a config switch).


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
