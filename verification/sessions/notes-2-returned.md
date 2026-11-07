# Notes guided session 2 — returned form

Run 2026-11-06, about 19:45–20:40, by the owner in an interactive session that kept the form as he spoke. Pack:
[`notes-2.md`](notes-2.md) (`W40.g2-notes-2`, updated that afternoon for Advanced Search). The session checked it
was time first. Directly after Reader guided session 2 ([`reader-2-returned.md`](reader-2-returned.md)).

**Build:** Debug, `main` at `c013d62b`, launched with `./launch.sh notes`. macOS 27.2, dark appearance. The Dock
showed the old icons until the session re-registered both apps with LaunchServices and restarted the Dock; the
built apps already carried set B.

**Session folder.** `notes-session-2/` per the pack: an APFS clone of `reader-sample/` (5,039 PDFs) as `archive/`
and an empty `store/`. Setup step 5 (choosing the archive in Notes) was missed at first, so Preview showed the
access message ([screenshot](notes-2-returned/notes-2-preview-access.png)); once chosen, Preview worked.

## Notes form

**Severity was not given by the owner; the session assigned it** from what he said. *?* rows are his suggestions,
decided at filing ("fix all, B first"). Parenthesised text is what the session found in the code or told him.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | setup | Changing the store folder restarts Notes into it | The confirm button says "Quit and Switch" and Notes only quits; it should be "Restart and Switch" and relaunch | C |
| 2 | 1 | The toolbar says plainly that this is the Notes window | Did not see the toolbar or any sign that this is the Notes window. (The screenshot shows a "Notes" label in the toolbar's pill beside the sidebar and document buttons: it is there but not noticed.) | A |
| 3 | 1 | The toolbar's label sits inside its pill, and one even title bar, as fixed in the Reader | The word "Notes" does not sit properly inside the toolbar's oval (it runs to its edge), and "Archive Notes" has two background colours behind it, grey over the sidebar and white to the right (screenshots [`notes-2-titlebar.png`](notes-2-returned/notes-2-titlebar.png), [`notes-2-titlebar-2.png`](notes-2-returned/notes-2-titlebar-2.png); macOS 27.2) | C |
| 4 | 1 | Round-up note's explanation on demand | The explanation under Round-up note should be in a tooltip or a ? button, not visible at all times | C |
| 5 | 1 | Tooltips on the formatting controls | The formatting controls have no tooltips | C |
| 6 | 1 | After a restart, the note that was open is open again | Restarting and reopening worked, but Notes should automatically open the last note that was open | ? |
| 7 | 1-2 | Underline and highlight among the formatting options | There is no underline or highlight; add them | ? |
| 8 | 3 | The inspector opens smoothly | Opening the inspector makes a lot of flicker, or rapid motion, in the note pane | A |
| 9 | 3 | One date field across the suite | Notes' typed date field is great; reuse it for dates in the Reader (Edit Info) and, where relevant, the Processor | ? |
| 10 | 3 | The Sent-with date visible in the list | Sent-with dates should be a separate column in the list | ? |
| 11 | 3 | Double-clicking a date cell and clicking away without a change leaves the date as it was | The date disappears: double-click the date in the list, change nothing, click away, and the date is gone | B |
| 12 | 3 | Tags in the list wrap as in the Reader; the two apps look and behave alike | Tags do not wrap in the list as they do in the Reader. In general the Reader and Notes need more standardization in appearance and function; the owner says this is important | A |
| 13 | 3 | The tags bar under the note spans the area | The tags bar under the note should run the full width of the area, with the tags shown in it as in the Reader's list | C |
| 14 | 3 | Only the fields the owner uses | We don't want an author field; remove it | ? |
| 15 | 4 | Dragging a folder onto another nests it, and back out un-nests it | Dragging folders does not work at all | B |
| 16 | 4 | Delete on ⌘⌫, as in Finder | The keystroke for Delete should be ⌘⌫ | C |
| 17 | 4 | Redo after undoing a delete deletes the note again | Undo of a delete works; Redo does not (the pack's known limit), and it should | A |
| 18 | 4 | A way to assign a template to a folder, and template fields in the inspector | Could not see how to assign a template to a folder. The inspector shows no options for a template. A template should be able to carry fields such as a date. (The assignment exists but was not found: a folder's right-click Template ▸ menu, `NotesModel.swift:56`; the Templates list says so only when empty.) | A |
| 19 | 5 | Only the filters that matter in the filter bar | Round-up as a choice in the note filter area is probably not needed; it is not that important | ? |
| 20 | 5 | A tag filter field big enough, that autocompletes | The tag search field in the note filter is far too small, and it does not autocomplete tags | A |
| 21 | 5 | The filter bar matches the Reader's | In general the filtering UI should match the Reader's | ? |
| 22 | 5 | Each part of the window can be shown or hidden | Options to show or hide the formatting bar, the title/year/info bar, the tags bar (tagging always possible in the inspector too) and the Folders pane, so the user can see just the filter pane, the list and the note text. The Markdown on/off toggle takes too much room | ? |
| 23 | 5 | Edit ▸ Advanced Search… with ⇧⌥⌘F | Advanced Search is not in the menu bar and ⇧⌥⌘F did nothing; opened it with the filter bar's icon. (The code adds it to Edit after the text-editing group, greyed when the window has not published its action, `ArchiveNotesCommands.swift:156`; so it was either missing or greyed and not seen. Reproduce.) | A |
| 24 | 5 | Tags in Advanced Search autocomplete and show as chips | In Advanced Search, tags do not autocomplete and stay plain words, not tag chips | A |
| 25 | 5 | Date means the item's own date; Sent with is a lower-level refinement | Demote Sent with below the item's own date in date forms (filters, Advanced Search, the inspector): few items have one and many users won't use it, so don't keep bothering the user with it. It stays searchable, but separately from Date, which defaults to the own date. Applies across the suite | ? |
| 26 | 5 | Clear All clears an Advanced Search too, and it is plain when one is in effect | Clear All and the date's own ⓧ work, but Clear All does not clear an Advanced Search. It should, and it should be more obvious that an Advanced Search is in effect; the Reader does this better (its In effect row) | A |
| 27 | 7 | Zotero links handled like any other paste | Both Zotero commands should have a keystroke. Better, detect a Zotero link when the user pastes it, instead of this special Attach command: why the special approach? | ? |
| 28 | 7 | Auto-fill from Zotero available on a note with a Zotero link | Note ▸ Auto-fill from Zotero… stays greyed; not clear how to make it available. (Read in the session: it is live only on a note, not an extract, whose links resolve to exactly one Zotero item, `ZoteroAutoFillReferenceResolver.resolve`; two different links make it ambiguous and grey it, and nothing says why. The reference is re-read when the selection changes, `NoteEditorPane.swift:491`. After the session's suggestions (reselect the note; check for a second link or an extract) Auto-fill worked, so it was greyed by one of those, not broken; which one was not said.) | A |

**The known problems above:** only Redo after a delete, which is row 17 (owner).

**Overall:** "Yes, after the B fixes" (owner): Notes for a real research day once the list's date cell keeps its
date (row 11) and folders can be dragged (row 15).

## What went as promised

- Task 1: making a note with ⌘N; titling in the header and renaming in the list, and the note stays selected; the title stays in the list after clicking away; typing, blank lines and Backspace joining; heading, bullets and a link; bold with its trailing space; after quit and reopen everything was there.
- Task 2: Reveal in the Reader opened each block's own page; Preview opened once the archive folder was chosen in Notes (setup step 5 had been missed; the message was right); Paste as Source Block(s) worked; Reveal in Finder worked; pasting a second link worked.
- Task 3: the typed date field at each precision is great; a Sent-with date by typing; tag suggestions while typing; editing date and tags by double-clicking the cell (but row 11); Reveal in Finder, and the Finder tags match. The Round-up note explanation reads well but should be a tooltip or ? (row 4 again).
- Task 4: dragging a note across the folder list lands it where it was put; Undo of a delete; the Trash and Put Back. After the hint, assigning the template from the folder's right-click menu and creating a note from it in that folder worked (a note, not an extract).
- Task 5: clearing only the year with its ⓧ, and Clear All for the filter bar; narrowing by year and tag; the scope control; List Above Note's divider; Advanced Search's form, Save as Smart Folder and Edit Smart Folder.
- Task 6: every shortcut worked (⌘N, ⌥⌘N, ⇧⌘O, ⌘F in a note, ⇧⌘C, ⌥⌘I, and ⇧⌘O from a Reader document window); the icons are fine for now.
- Task 7: Auto-fill from Zotero worked once it was live; Attach Zotero Link's chip shows a citation (author, title, date), not a code.

For the ledger (the filing item moves the rows): each task's ledger rows are in its brackets in
[`notes-2.md`](notes-2.md). Folder nesting by drag (N-26, task 4) failed its recheck (row 15); the date cell (task 3)
went wrong when left unchanged (row 11); the rest of each task's checks went as listed above.
