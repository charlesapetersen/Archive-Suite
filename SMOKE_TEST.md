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

- [ ] **A. Launch + discovery** — point the app at `~/Desktop/AR-Smoke`; list shows 30 rows,
      "30 shown · 30 total", spinner appeared during gather.
- [ ] **B. Chronological sort (default)** — rows ascend by document date; undated markers sort last.
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
- [ ] **N. Mark Read (⌘R)** on a scratch selection — rows leave an Unread view; status updates.
- [ ] **O. Undo (⌘Z)** — the mark-Read reverts; rows return.
- [ ] **P. Mark Unread (⌘U)** works.
- [ ] **Q. Tag editor (⌘I)** — add a subject / set priority on scratch selection; verify; undo.
- [ ] **R. Flag (⌘⇧F)** — flag column fills; toggles off.
- [ ] **S. Saved search** — save current filters; apply from the Saved menu.
- [ ] **T. Options (⌘,)** — settings window opens; a toggle persists.
- [ ] **U. Menu bar** — File/Selection/Tags/Sort&Filter/Document present; a menu command works.
- [ ] **V. Library health** — the stethoscope popover shows sensible counts.

## Results & notes
(filled in as steps run)
