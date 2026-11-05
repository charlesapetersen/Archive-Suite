# Reader guided session 1 — returned form

Run 2026-11-04, about 18:00–18:45, by the owner in an interactive session that kept the form as he spoke. Pack:
[`reader-1.md`](reader-1.md) (refreshed by `W40.g1-refresh` 2026-10-31). The session judged it was time first (no
open Reader fix items; the queued Reader work, W47.ct-reader-view/-edit and W44.reocr-reader, is blocked well
behind other work; the two Reader fixes since the refresh, W48.reader-copy-shortcut and
W40.fix-reader-ledger-durability, only help tasks 3 and 7).

**Build:** Debug, `main` at `3fad9cb3`, launched with `./launch.sh reader`. Dark appearance.

**Sample.** `reader-sample/` had moved to the OneDrive backup (31 Oct), so it was rebuilt rather than copied back:
`python3 ArchiveReader/scripts/rehearsal-sample.py make` (defaults, seed 402), 98 s, APFS clones. 5,000 PDFs, 8,747
files, 8.47 GiB; sampled corpus files and corpus roots identical before and after, copy faithful 8,747 of 8,747
(`reader-sample/MANIFEST.txt`, made 2026-11-04 17:25). The selection differs from the October sample
(`selection.tsv` `821c4518…`, was `f1217588…`) because the corpus walked was smaller: **91,152 PDFs in 255 folder
groups, against 102,478 in 270 on 2026-10-14**, with the JPEGS tree unchanged at 98,884. The owner was told; whether
the missing PDFs were moved on purpose is his to say. The session copy `reader-session-1/` was cloned from it per
the pack.

## Notes form

Severity as the owner gave it; "not given" where he gave none. **Owner, at the end of the session: "Everything
I've mentioned here should be fixed."** So the rows marked *design* below are decided, not questions for the Daemon
Report, with one exception (row 24, Notes in the Reader). Bracketed text is what the session found in the code or
told him.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | 1 | Everything in reach at the narrowest window | At the narrowest window, the Read column disappears from the list | C |
| 2 | 1 | The health counts shown when they matter | "931 needs attention" and "104 ambiguous dates" are always visible; the user doesn't need constant reminding | design |
| 3 | 1 | To know what the ⚑ (Flag) column is and does | Not clear; no tooltip, and nothing explains it on right-click in the header | design |
| 4 | 1 | To sort by Flag and by the ⚠︎ needs-attention column | Neither column sorts [`sortField: nil` for both in `AppKitTableView.columnDefinitions`] | design |
| 5 | 1 | A visible control (a chip) to customise the columns | Column choice is only in the header's right-click menu, so optional columns such as Provenance are hidden from the user | design |
| 6 | 1 | To know what the Provenance column is | Unclear [explained: the page-2 classification marker, Box / Folder / Document Start / Continuation; display-only, hidden by default. Weigh with W47's Container column] | design |
| 7 | 2 | (everything worked) | The Filter file name and Search OCR text fields would be better a little larger, on their own line | design |
| 8 | 2 | To see at a glance which filters and searches are in effect | Searched a name, then clicked another person's folder in the tree: an empty list, and easy to forget the search still applied. Keeping the search is right; what is in effect should be very apparent | not given |
| 9 | 3 | An easy way to change the OCR text size, such as ⌘+ / ⌘− | Not found [Zoom In/Out are ⌘↑ / ⌘↓ on the focused pane, Document menu; ⌘+ / ⌘− are unbound] | design |
| 10 | 3 | To know what the second pair of magnifying glasses in the document window does | Unclear; they don't seem to do anything | not given (reproduce: possible bug) |
| 11 | 3 | The expansion arrows in the document window to do something | They don't seem to do anything | not given (reproduce: possible bug) |
| 12 | 3 | Find to search the image PDF and the extracted text at once, highlighting each hit in both | Find works in one pane | design |
| 13 | 3 | An easy switch to the JPEG original, in the document window's toolbar as well as the menu | Didn't find an easy way to switch | design |
| 14 | 3 | Hide Sidebar / Hide Tag Cloud only when the file navigator is in front | Both still show in the menu bar while the document viewer is in front | design |
| 15 | 3 | Copy Cleaned for Prose and Copy Archive Link to This Page under Edit; a shortcut for Copy Archive Link to This Page | Both are in the Document menu (Cleaned for Prose is ⌥⌘C); the page link has no shortcut | design |
| 16 | 3 | Copy Cleaned for Prose to remove line breaks but keep paragraph breaks | [It already does: `CopyTextCleaner` joins single newlines, keeps blank lines as paragraph breaks, de-hyphenates; each switchable in Options] | — (see 19) |
| 17 | 3 | Preview to be instantaneous | The text appears at once, the image a moment later | not given |
| 18 | 3 | Zoom In to enlarge the text page | Nothing visible changes, even after Document ▸ Focus Text Page | not given (reproduce: likely bug, a promised feature) |
| 19 | 3 | Copy Cleaned for Prose to keep paragraph breaks the OCR didn't mark | The OCR sometimes gives no blank line at a paragraph break, so paragraphs merge; improve it [needs layout, e.g. first-line indent or a short last line, from the text layer's line positions] | design |
| 20 | 4 | The Tags menu to work while reading a page in the document window | Every Tags item is unavailable there [by design today: the menu acts on the list's selection] | design |
| 21 | 4 | Redo after undoing a Read change | Undo works; there is no Redo | design |
| 22 | 4 | To see the Provenance column filled | Empty for every file [expected: the corpus predates the apps, so its PDFs carry no page-2 classification header. A column that is blank for most users' existing material needs a rethink] | design |
| 23 | 4 | Toggle Flag (⇧⌘F) to show a flag | Doesn't appear to do anything | not given (reproduce: likely bug) |
| 24 | 4 | To know what Notes are and where they appear | Unclear [app-side notes and flags in `NotesStore`, never written to the file; a note shows only in Edit Tags…]. **Owner: "I don't know that I asked for Notes to be created here and I'm not sure I actually want them. We have an entire Notes program for a reason."** | **open question (Daemon Report)** |
| 25 | 4 | A note to save itself as it's typed | It needs a click on "Save note" | design (moot if 24 removes notes) |
| 26 | 5 | A slider on the tag cloud to set the minimum count a tag needs to be shown | No such control | design |
| 27 | 5 | Edit Tags to say "Tags", and the app to call them tags everywhere | The sheet labels them "Subjects" | design |
| 28 | 5 | Tags to autocomplete in Edit Tags | They don't (they do in the list's tag field) | design |
| 29 | 5 | To add several tags in a row in the list's tag field | The field loses focus after each tag; a click is needed for every one | not given |
| 30 | 5 | Tags that differ only in case to be the same tag, keeping the case as typed | They are separate tags [a shared-contract change: `SPEC/tag-format.md`, both apps, Tier-2] | design |
| 31 | 5 | A name for Edit Tags that fits all it does (tags, quality, Sent-with date, note) | "Edit Tags…" undersells it | design |
| 32 | 5 | ⌘Z in the file-name filter to undo the typing | **It undid the last tag change; the typing stayed. Confirms suspect `S-001`.** With no Redo (row 21) the undone tag can be restored only by hand | not given (the filer sets S1–S3) |
| 33 | 6 | (Find worked as expected) | An Advanced Search as well | design (feature) |
| 34 | 7 | One even background behind the window title | A split gradient behind "Archive Reader" in the title bar, at the sidebar's edge ([`reader-1-returned-titlebar.png`](reader-1-returned-titlebar.png)) | not given |
| 35 | 7 | Relaunch to return to the place in the list I was looking at | It returned to the smart folder but, the owner thinks, not to the same rows | not given |
| 36 | 5, 7 | In the list's tag field, to stop partway through an autocompletion, type a space and start the next tag | The autocompletion forces the rest of the suggested word before a space can be typed | not given |
| 37 | 7 | ⌘Z straight after relaunch to undo the change made before the quit | Nothing happened until the owner clicked in the file list; then ⌘Z undid it [nothing has focus at launch] | not given |
| 38 | 8 | To know where to paste a copied archive link to open it | Not obvious [an `archivereader://` link: Archive Notes, Apple Notes, Mail, Messages, Safari's address bar] | design |
| — | 8 | The file link and the page link to bring me back to the right place | Both work | — |

**The known problems above:** which ones got in your way, and how much?
Notes in the Reader: see row 24 (the owner doubts they belong in the Reader at all). Search snippets: **"Search
snippets is important"**, so the missing-snippet limit (a slow several-word search leaves some hits without a
snippet) should be fixed, not kept as a known problem.

**Overall:** not answered as such. The owner's direction instead: everything on this form should be fixed.

**Anything else:** the owner's priority order for the fixes (owner, 2026-11-04):
1. **Clean copy improvements** — rows 19 and 16; with them the Edit-menu move and its shortcut (row 15).
2. **Easy wins moving or creating shortcuts and menu items** — rows 9, 13, 14, 15, 20, 38.
3. **Fixing tagging** — rows 27, 28, 29, 30, 31, 32, 36, and Redo and the undo focus (rows 21, 37).
Then the rest.

## For the session that files the notes

The pack's filing rules apply, with the owner's call above changing one of them: a *design* row is filed as a
`W40.fix-reader-<slug>` item (or a feature item where it is new work, e.g. rows 12, 26, 33), not as a Daemon Report
question. Only row 24 goes to the Daemon Report. Rows 10, 11, 18 and 23 need a reproduction first; if one cannot be
reproduced it becomes a `SUSPECTS.md` entry ("Raised: owner session reader-1"). Row 32 closes `S-001` as confirmed and
is filed as a fix on an irreversible path. Row 30 is a shared-contract change. Order the items by the owner's
priority list. `reader-session-1/` is kept until the notes are filed.
