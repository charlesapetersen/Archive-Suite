# Reader guided session 2 — returned form

Run 2026-11-06, about 17:30–19:30, by the owner in an interactive session that kept the form as he spoke. Pack:
[`reader-2.md`](reader-2.md) (`W40.g1-reader-2`). The session checked it was time first: every session-1 row had
shipped, no Reader fix item was open, and the two Reader changes since the pack (Clear All, 12:02; the archive
identity written on choosing a folder, 10:13) touch no task's result.

**Build:** Debug, `main` at `2db2f7f9`, launched with `./launch.sh reader`. macOS 27.2, dark appearance.

**Sample.** `reader-session-2/` cloned from `reader-sample/` per the pack's step 1: 5,039 PDFs (the 2026-11-04
sample, `reader-sample/MANIFEST.txt`).

## Notes form

**Severity was not given by the owner; the session assigned it** from what he said (B where a command did something
wrong or nothing). The filing session confirms each against a reproduction. *?* rows are the owner's suggestions or
questions, for the filing call. Bracketed or parenthesised text is what the session found or told him.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | 1 | The stethoscope's popover shows the health statistics updating live while the index builds | Clicking the stethoscope, the statistics do not update live | A |
| 2 | 1 | Clicking a file's ⚠︎ in the list reveals what the issue is and how to fix it | The alerts show beside files with a health issue, but it is not clear how to see exactly what the issue is or how to fix it; clicking the alert in the list should do something | A |
| 3 | 1 | Columns turned on and off from the column headers themselves | The Columns chip works; it should be built into the columns (header menu) if possible, otherwise fine | ? |
| 4 | 1-2 | A sort indicator (caret) on the column being sorted, as on the others | No caret or similar shows when sorting by ⚑ or ⚠︎ | C |
| 5 | 2 | The In effect row lists filters and searches | The folder (the sidebar selection) appears in the In effect row; it should not be included, I think | ? |
| 6 | 3 | The arrow keys move (pan) the image in the document window | The arrow keys do nothing in the document view | A |
| 7 | 3 | Clicking the text pane on the right gives it the focus | Clicking the text on the right does not seem to shift focus | A |
| 8 | 3 | On a document with no JPEG, the PDF / JPEG switch is greyed or not offered (the pack says greyed, with a tooltip) | No JPEG seemed to be available for 00114 Young papers.pdf, but the JPEG option was offered | A |
| 9 | 3 | Clear View menu items | Not sure what "Show All Tabs" does. For multi-page documents, an option to view all pages tiled | ? |
| 10 | 3 | Edit ▸ Copy works on a selection | Regular Copy is greyed out | B |
| 11 | 3 | Copy (any of the copy commands) copies the text selected in the text pane on the right | None of the copy functions copy from the text pane; they copy only from the image on the left | B |
| 12 | 3 | It is unambiguous what a copy takes | With a selection in both panes at once it is ambiguous where the copy comes from; allow one live selection, in either pane, at a time | ? |
| 13 | 4-5 | The status line says what was undone or redone, and to what | It says only "Undo 1 change" / "Redid 1 change"; more detail would help (what changed, from what to what) | ? |
| 14 | 5 | Edit Info as a Mac-like inspector | Edit Info should become an inspector, a right-hand column the user can keep open all the time (as Notes did) | ? |
| 15 | 5 | A tag appears at once after Return or Tab | Adding tags works well, but the tags appear a bit slowly after Return or Tab; it could be faster | C |
| 16 | 5 | Tabbing to the Month field and typing chooses a month | After tabbing to Month, typing does not choose a month; it has to be clicked first, then typing works | A |
| 17 | 5 | Month shown as the user expects | Should the leading zero ("01") be retired? The owner writes it that way, but users may find it strange, and it matters less now that dates are set in the app | ? |
| 18 | 5 | A clear label for the Sent-with date | "Sent with" will confuse readers; make clearer what that section is for | ? |
| 19 | 5 | The tag cloud's threshold can be moved quickly | The stepper is only up/down arrows; it should be a slider or similar so the user can move rapidly through the values | C |
| 20 | 5 | ⌘Z in the file-name filter undoes typing step by step | Undo in the file-name filter works, but seems to have only one level | A |
| 21 | 5 | The Sent-with date is set with the same control as the document date | The Sent-with date's tools differ from the main date's; it seems weird | A |
| 22 | 6 | Search OCR text matches only the OCR text | Searching "Riesman" brings up files with Riesman in the file name but not in the OCR text. (Read from the code in the session, not reproduced: the FTS table indexes body, classification and name, `ContentIndex.swift:60`, so an unqualified query matches file names too.) | B |
| 23 | 6-7 | A smart folder in the sidebar shows its item count, as folders do | Smart folders have no item counts; they should | C |
| 24 | 6-7 | Opening a smart folder shows the files that fit its rules, without snippets; snippets come when the user searches text | A smart folder shows snippets even when the user is not searching text (its OCR-text rule brings them). It should simply list the matching files | ? |
| 25 | 8 | No explanation needed after copying a link | The status line's explanation of where a link opens (row 38's fix) is not needed | ? |

**The known problems above:** none got in the way (owner).

**Overall:** "Yes, after the B fixes" (owner): he would use the Reader for a real day of triage once Copy works
from the text pane (rows 10-11) and Search OCR text stops matching file names (row 22).

## What went as promised

- Task 1: Library health popover works well; ⚑ and ⚠︎ tooltips and sorts work; resizing to the narrowest works well (Read column in view).
- Task 2: plain what is still in effect; the search fields are a good size; the empty view is good.
- Task 3: Find in both pages works well; text size changes work well; Copy Cleaned for Prose works for now (more detailed work later, owner); preview is fast now.
- Task 4: Mark Read & Next Unread at a good pace; the flag shows at once; Undo and Redo work. (Mark Read & Next Unread from a document window not mentioned separately.)
- Task 5: adding tags works well (keyboard and Tab completion); the case message and spelling, tagging three files at once, the two-word tag in a row's field, emptying the Sent-with date, and the tags ending up as meant all worked (owner: "yes to everything else").
- Task 6: snippets work on every hit with text; Advanced Search works well; the count follows edits; Save as Smart Folder and Edit Smart Folder work.
- Task 7: after quit and relaunch the list came back at the row; ⌘Z straight away undid the change from before the quit; the title bar is one even background in light and dark (macOS 27.2, the owner's Mac).
- Task 8: both links (file, ⇧⌘L; page, ⌥⌘L) brought the owner back to the right file and page.

So, for the ledger (the filing session moves the rows): the title bar on macOS 27 (row 34's fix), Copy Cleaned for
Prose's paragraph breaks on real OCR (row 19's fix) and the preview image speed on real scans (row 17's fix), the three
fixes never seen on the owner's pages, were seen working. Mark Read & Next Unread from a document window (task 4) was
not reported on separately. Task 5 wrote tags into `reader-session-2/`, which stays until the notes are filed (R-45,
R-46 move only on what is on disk there).
