# Archive Reader — Interactive GUI Smoke Test

Durable record of the manual/driven GUI smoke test. **Resumable:** if interrupted, re-run
`./scripts/smoke-setup.sh`, relaunch the app pointed at `~/Desktop/AR-Smoke`, and continue at the
first unchecked step. Driven with `screencapture` (see) + `osascript`/System Events + `cliclick`
(interact). Screenshots land in `.maintenance/smoke/` (gitignored); results are recorded here.

**Safety:** the test runs against a SCRATCH corpus of COPIES (`~/Desktop/AR-Smoke`, 30 tagged PDFs),
never the real `Test files/` corpus. Mark-Read / tag edits therefore never touch the corpus.

- **Environment:** Screen Recording + Accessibility granted; `cliclick 5.1`; app built Debug at
  `ArchiveReader/build/DD/Build/Products/Debug/ArchiveReader.app`.
- **Legend:** [ ] pending · [x] PASS · [!] FAIL (see note) · [~] partial/NA

## Steps

- [x] **A. Launch + discovery** — point the app at `~/Desktop/AR-Smoke`; list shows 30 rows,
      "30 shown · 30 total", spinner appeared during gather. **PASS** (2026-07-05, fresh build).
- [x] **B. Chronological sort (default)** — rows ascend by document date; undated markers sort last.
      **PASS** — Sep 1980 → Oct 1980 → Sep 1982 → undated Red markers (00001/00006) last.
- [ ] **C. Read-state filter** — Unread / Read / No read-state / All change the row set correctly.
- [ ] **D. Priority filter** — P10/P9/P8/P7 toggles narrow to matching rows; combine with read-state.
- [ ] **E. Subject filter** — add a subject (e.g. "Jerry Brown"); AND/Any behaves; chip removes.
- [ ] **F. Filename filter** — typing narrows by file name; Space typeable in the field (no preview).
- [ ] **G. Full-text OCR search** — a term returns matching files (content index); Clear resets.
- [ ] **H. Sort menu** — Sort by File name / Priority; reverse direction.
- [ ] **I. Open two-up viewer (⌘O / double-click)** — image left, OCR text right; title/position.
- [ ] **J. Viewer: ↑/↓ cycle**, splitter drag resizes, per-pane zoom, **top-anchored zoom**.
- [ ] **K. Viewer: ⌘C intelligent copy** (clipboard has cleaned prose), **⌘F find** highlights.
- [ ] **L. Preview (Space)** — 2-up preview sheet; ←/→ cycles; Esc closes; Space typeable in filters.
- [ ] **M. Copy links (⌘⇧C)** — clipboard has correctly-encoded file:// links.
- [x] **N. Mark Read** on a scratch selection — status updates; **the row now displays "Read" and
      HOLDS it** through the Spotlight-update window. **PASS** (fresh build). This is the fix for the
      two compounding bugs below.
- [x] **O. Undo (Tags→Undo Tag Change)** — 00015 reverts to "Unread" (display + disk), status
      "Undid 1 change"; holds. **PASS**.
- [ ] **P. Mark Unread (⌘U)** works.
- [ ] **Q. Tag editor (⌘I)** — add a subject / set priority on scratch selection; verify; undo.
- [ ] **R. Flag (⌘⇧F)** — flag column fills; toggles off.
- [ ] **S. Saved search** — save current filters; apply from the Saved menu.
- [ ] **T. Options (⌘,)** — settings window opens; a toggle persists.
- [ ] **U. Menu bar** — File/Selection/Tags/Sort&Filter/Document present; a menu command works.
- [ ] **V. Library health** — the stethoscope popover shows sensible counts.

## Results & notes

### 2026-07-05 — mark-Read display bug: TWO compounding bugs found & fixed
Marking a file Read left the row showing "Unread" (disk was correctly `Read`; status said "Marked 1
Read"). Live GUI testing on the scratch corpus + code review (multi-agent) found this was **two**
bugs stacked, which is why the earlier pre-compaction diagnosis (Spotlight clobber alone) looked
incomplete:

1. **Render-skip (primary, masked the other).** `ArchiveFile: Equatable` compared **only `url`**, so
   SwiftUI's `Table` diffed a row whose *tags* changed (Unread→Read) as "unchanged" and skipped
   re-rendering its cell. The row never showed "Read" at all — even the old optimistic code (which
   definitely set Read in the model) displayed "Unread". Fix: value-based `==` (incl. `tags`) in
   `ArchiveFile.swift`; identity for selection remains `id` = url.path.
2. **Spotlight clobber.** After a verified `TagWriter` write, Spotlight fires `…DidUpdate` but
   re-emits the stale `kMDItemUserTags` before re-indexing, so `reload()` overwrote the correct value.
   Fix: `ArchiveLibrary.applyVerifiedWrites` overlays `TagWriter`'s verified `.after` per URL and
   `reload()` keeps it until Spotlight value-converges or a 600s TTL leak-guard (never backslides).
   Display-only (no disk write/read); pure `overrideDecision` unit-tested (8 tests).

Both were needed: #1 hid #2 (we never saw "Read" to watch it revert). Verified live on the fresh
build: Mark Read → row shows "Read" and holds ≥6 s; Undo → reverts to "Unread" and holds. Disk truth
matched at every step (`xattr`), Core Directive intact.

(Remaining checklist steps filled in as they run.)
