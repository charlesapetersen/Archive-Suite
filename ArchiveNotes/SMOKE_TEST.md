# Archive Notes — Interactive GUI Smoke Test

Durable record of the manual/driven GUI smoke test — the "did the app actually work end-to-end for a
human" pass that complements the unit gate. **Resumable:** if interrupted, rebuild the scratch fixture
(`scripts/make-notes-fixture.sh`), relaunch pointed at it (below), and continue at the first unchecked
step.

**Two gates, both cheap:**
- **Unit smoke** (no GUI, no corpus): `./test-smoke.sh notes` (repo root) or `cd ArchiveNotes &&
  ./test-smoke.sh` — build + the full `ArchiveNotesTests` unit suite. Run this before every push.
- **Driven GUI smoke** (this file): launch the app against a **scratch** store and drive it with
  [`scripts/gui-drive-notes.sh`](scripts/gui-drive-notes.sh) (`cliclick` for pointer input, `osascript`
  for keys/menus) + capture-and-read, or run the `ArchiveNotesUITests` XCUITest suite for deterministic
  assertions. The **detailed automated check catalog (G0–G11), including the owner-eye checks** (G2
  typing gesture, G6/G11 external Reader/Zotero launch, chip-button clicks), lives in
  [`scripts/GUI-HARNESS.md`](scripts/GUI-HARNESS.md) — not duplicated here. This file is the
  higher-level user-flow record.

> **Safety (Prime Directive #1 — see [GUI_SAFETY.md](GUI_SAFETY.md)):** every step runs against a
> **scratch** store of copies —
> `~/Library/Application Support/ArchiveNotes/AN-GUI-Fixture` (a *sibling* of the real `…/Store`, never
> it), built by `scripts/make-notes-fixture.sh` and reached via the DEBUG `-ANUITestStorePath` launch
> arg (in-memory only — **never** drive File ▸ Choose Store Folder…, which would persist a bookmark
> over the owner's real store). A DEBUG scratch-write guard in `NotesTagProjector` mechanically aborts
> any tag write outside scratch under a test/GUI-drive context. Assert tag writes by **reading**
> (`tag -l`); writes go only through the app.

- **Legend:** `[ ]` pending · `[x]` PASS · `[!]` FAIL (see note) · `[~]` partial / covered indirectly
  (unit-tested + "opens correctly") · `[owner]` owner-eye (needs real Reader/Zotero/typing gesture).

## Steps

- [ ] **A. Launch + store discovery** — point the app at the scratch fixture; the Notes window lists
      the fixture notes; the `an.status.indexReady` probe flips ready.
- [ ] **B. Folder tree + scope** — sidebar shows All Notes / folders / Smart Folders; selecting a
      folder scopes the list to its members (counts match).
- [ ] **C. Kind featuring** — the Notes window features notes, the Extracts window features extracts
      (the kind segmented control + per-window default).
- [ ] **D. Sort** — list re-orders by title / date / kind / quality; nil-last is stable.
- [ ] **E. Keyword full-text search** — as-you-type (bm25) narrows the list; a nonsense query → 0 rows;
      clearing restores. Auto-relevance sort while querying.
- [ ] **F. Quality / tag / date-range filters** — ★ toggles, tag ALL/ANY chips, and a year range each
      narrow the list; Save-as-Smart-Folder captures the active filter; Clear resets the user layer.
- [ ] **G. Open a note + edit body** — the detail pane binds to the selected note; typing autosaves
      (flush-on-switch); the raw-Markdown toggle (⌘/) round-trips styled ⇄ raw without data loss.
      *(typing gesture is `[owner]` per GUI-HARNESS G2.)*
- [ ] **H. Provenance chip** — a note/extract with a source block renders a chip; **Jump to Source**
      selects+scrolls the source; **Preview** shows the source page (chip-button clicks are `[owner]`).
- [ ] **I. Create / append extract (⌘⌥E)** — from a selected passage: the Extracts window fronts and
      selects the new/updated extract; the extract carries its own embedded copy of the passage bytes
      (snapshot-independent; source note untouched).
- [ ] **J. Zotero attach** — Note ▸ Attach Zotero Link… records the ref; a Zotero chip renders. Real
      Zotero fetch/auto-fill is `[owner]` (needs a running Zotero).
- [ ] **K. Durable-link resolve / re-grant** — a `reader-page` source block resolves and previews; a
      moved source root offers an in-app re-grant that re-resolves by GUID (wrong folder rejected).
      *(Build-free proof: `scripts/e2e-durable-links.sh`; unit gate: `DurableLinkE2ETests`.)*
- [ ] **L. Metadata edit** — date and quality edits in the inspector persist to front-matter; quality
      1–3 also mirrors Q1–Q3 only onto the note's own `.md`, while clear/0 removes its Q token. Author /
      title / subject editing land as the gap-closure Phase B items wire in.
- [ ] **M. Replication + delete-last-instance guard** — replicate a note into a second folder
      (membership, not a copy); removing a replicant is quiet; removing the **last** instance prompts a
      modal (fresh re-check at confirm) → Trash (recoverable).
- [ ] **N. Options (⌘,)** — the Settings window shows the Zotero section (enable / clipboard-detect /
      citation style / advanced host+port), @AppStorage-bound.
- [ ] **O. Tag projection (Tier-2, scratch only)** — set Quality 1–3 and assert Q1–Q3 on the note's
      **own** `.md` via `tag -l`; set 0/clear and assert no Q token. A user Finder tag and color label
      must remain; corpus never touched; the retired `ArchiveSuite` stamp is stripped while every other
      tag remains.
- [ ] **P. Quit** — `osascript -e 'quit app "ArchiveNotes"'`; the terminate flush drains any pending
      autosave debounce so a force-quit within the window can't lose an edit.

## Results & notes

_(No live GUI smoke run recorded yet — the driven runs are gated on GUI mode being ON; the unit smoke
gate is green. Record each pass here with the date + build, the scratch fixture used, and any bugs
found, following the Reader `SMOKE_TEST.md` precedent. Every scratch mutation must be confirmed against
on-disk truth, and the write surface must never touch corpus bytes or location — Core Directive.)_
