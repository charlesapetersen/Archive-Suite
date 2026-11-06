# Notes guided session 2

About 45 minutes in Archive Notes, going back over the tasks that drew notes in session 1
([`notes-1-returned.md`](notes-1-returned.md)), on a fresh copy of the same 5,000-PDF sample. Work as you would
on a research day. Whenever something confuses you, feels slow, or gets something wrong, write one line on the
form at the end. Short notes are enough, and so is "I expected X". The next daemon session turns each note into a
reproduced bug, a design question for you, or a suspect (`verification/SUSPECTS.md`).

Prepared by `W40.g2-notes-2` on 2026-11-06. Updated the same afternoon in an interactive session: Notes' Advanced
Search shipped at 10:05 (`W40.notes-advanced-search`), so it is no longer a known problem and task 5 now tries it.

**Is it time? Yes (judged 2026-11-06, checked again that afternoon).** Every row you filed in session 1 has a fix
that has shipped. No Notes fix item is open, and the Notes work still queued does not change what these tasks look
at: the box and folder in source blocks (`W47.ct-zotero`) waits for your sign-off on the containers design, and tag
rename across the apps (`W40.tag-rename-suite`) starts with a design note. The Reader fixes from your Reader session have shipped too; the
Reader items still open (the title-bar gradient, scroll position after a relaunch, Advanced Search) are not in
these tasks. One thing was checked first. A test of the real Reader's page link failed on 2026-11-05. The cause
was the test: it still looked under Document for a command that has moved to the Edit menu. The test was
corrected and passed in the VM.

**What changed since session 1** (your row numbers in brackets):

- ⌘N and File ▸ New Note are in the menu bar, with New Extract (⌥⌘N) and New Template…. Each window says in
  its toolbar whether it is the Notes or the Extracts window, and the toolbar's New offers both kinds. A new
  template asks which kind it makes. [5, 38, 39, 43]
- Return adds blank lines and Backspace joins lines, also after you reselect the note. Bulleted List makes a list
  with a visible bullet. Bold that ends in a space stays bold. [8, 10, 11]
- A title renamed in the list keeps the note selected. The title in the note's header can be clicked and
  edited. [6, 14] The title vanishing after a deselect [9] could not be made to happen again, so watch for it.
- **The fields moved to an inspector** (your choice of layout): a panel on the window's right, View ▸ Show/Hide
  Inspector (⌥⌘I) or the toolbar button. It holds Round-up, Authors, Date with Sent with, Quality, Locations and
  Zotero. The Details strip is gone. Tags are in a bar under the note. Date and Tags can be edited in the list
  by double-clicking the cell, or with Edit Date / Edit Tags in the row's menu. [7, 15, 20, 21, 23, 32]
- A date is one typed field. `1960s`, `1968`, `March 1968` or `12 March 1968` set the precision themselves. It
  applies on Return or when you leave the field, and an emptied field clears it. There are no Set, Clear or
  precision buttons. [22]
- Tags autocomplete from your other notes; Return or a comma adds one, and Tab takes the suggestion. There is no
  Add button. [26]
- No Set or Clear buttons anywhere in the suite: Notes' Authors and the Reader's Edit Info sheet now apply as you
  type too. [25]
- Round-up note says what it does, under the switch. [24]
- Dragging a folder onto another nests it, and the highlighted folder is the one the drop will land in. [30, 31]
- Delete then Edit ▸ Undo brings the note back. The sidebar has a Trash, with Put Back and Empty Trash…. [34, 40]
- File ▸ New Template…, and templates are renamed in their list as notes are. [35, 41, 42]
- The filter bar's date has its own ⓧ, Clear became Clear All, and the All/Any choice beside Tag… is gone (it
  belongs in Advanced Search). [37, 47]
- The scope control reads All · Notes · Extracts. Page thumbnails in a note are smaller than the preview. List
  Above Note's divider drags much further. [19, 36, 45]
- Zotero: Notes asks Zotero for the item directly instead of first listing your whole library, which is the likely
  reason it gave up on yours in session 1. A failure now says in a sentence what to check, and an attached link
  fills in its citation when Zotero answers. [50, 51]
- Shortcuts were checked across the three apps. In Notes, Choose Archive Folder… is ⇧⌘O as in the Reader, the
  lists moved to ⌥⌘U and ⌥⌘O, Note ▸ Copy Link is ⇧⌘C, and Edit ▸ Find (⌘F) searches the note. The full
  table is in `ArchiveNotes/REFERENCE.md` §Keyboard map. [1, 3]
- Each app has its own icon: set B, which you chose on 2026-11-06. [4]
- Choosing a folder in the Reader, or with File ▸ Choose Archive Folder… in Notes, now gives it its archive
  identity, so Notes no longer asks you to open the folder in the Reader and copy a link first. Notes refuses only
  a folder it cannot use, such as one it cannot write to, and says why (`W40.root-marker-auto`). [2, 2a]
- **Advanced Search** (Edit ▸ Advanced Search…, ⇧⌥⌘F, or the Advanced Search button in the filter bar):
  Finder-style rule rows, as in the Reader. Rules for any text, note text, title, authors, tags (all, any or none
  of them), kind, quality, date (between, after, before or missing), date uncertain, folder and round-up, with All
  or Any and nested groups. The form shows a live count. Save as Smart Folder… keeps a search, and Edit Smart
  Folder… on a smart folder opens it again. [37, 47]

## Before you start (5 minutes, not counted)

1. **Make the session folder.** One command makes an APFS-clone copy of the Reader sample (quick, almost no disk)
   and an empty folder for a new Notes store beside it:
   ```bash
   cd ~/Library/Caches/ArchiveSuiteRehearsal && rm -rf notes-session-2 && mkdir -p notes-session-2/store && \
     mkdir notes-session-2/archive && \
     cp -c -R -p "reader-sample/Archival Photos" "reader-sample/Archival Photos JPEGS" notes-session-2/archive/
   ```
   None of this touches your real collection. The sample was copied out of it read-only on 2026-11-04
   (`reader-sample/MANIFEST.txt`). If `reader-sample/` is not there, it has moved to the backup: rebuild it with
   `python3 ArchiveReader/scripts/rehearsal-sample.py make` (about 100 s). Session 1's folder,
   `notes-session-1/`, has been filed and can be deleted: `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/notes-session-1`.
2. **Start the Reader and point it at the copy.** `cd ~/Claude/"Archive Suite" && ./launch.sh reader`, then
   File ▸ Choose Archive Folder… (⇧⌘O), ⇧⌘G, paste `~/Library/Caches/ArchiveSuiteRehearsal/notes-session-2/archive`
   and choose it. Choosing the folder gives it its identity file, so Notes accepts the same folder with no
   further step (W40.root-marker-auto).
3. **Start Notes:** `./launch.sh notes`.
4. **Point Notes at the new store:** File ▸ Choose Store Folder…, ⇧⌘G,
   `~/Library/Caches/ArchiveSuiteRehearsal/notes-session-2/store`. Notes asks to confirm, then quits; start it
   again with `./launch.sh notes`. The list should be empty.
5. **Point Notes at the archive:** File ▸ Choose Archive Folder… (⇧⌘O), the same `notes-session-2/archive`.
6. Keep this file open beside the apps and write on the form at the bottom, here or on paper.

## Problems we already know about

Only those that will stay open for a while:

- **A source block does not show the box and folder its document came from, and there is no Copy for Zotero yet.**
  Both are `W47.ct-zotero`, waiting on the containers design. Tasks 2 and 7.
- **Small limits of the fixes, left on purpose:**
  - Undo brings back a deleted note but Redo does not delete it again.
  - Undo does not bring back a deleted folder. Its notes are in the Trash for Put Back.
  - In a Tags cell in the list, Escape with the suggestion list open cancels the whole edit.
  - At the narrowest window with the inspector open, the list needs a sideways scroll to reach Tags.

  Tasks 1, 3 and 4.
- **The Reader** is used here only to read and copy links. Leave notes about the Reader to its own next session.

## The tasks (45 minutes)

The minutes are a guide. If one task is going badly, note it and move on. The brackets give session 1's rows and the
ledger rows each task covers, for the session that files your notes. You don't need them.

1. **A first note (7 min).** Make a note with ⌘N, from the menu bar. Check the toolbar says you are in the Notes
   window. Give the note a title by clicking the title in the note's header. Rename it again in the list (Return
   or double-click), press Return, and check it stays selected. Click another note and come back: is the title
   still in the list? Type several paragraphs with blank lines between them, delete a blank line with Backspace,
   and add a heading, a bulleted list (⌥⌘U or the toolbar), a bold word selected together with the space after it
   (the case that came back as asterisks), and a link. Click away to another note and back, then ⌘Q, start Notes again and reopen it: are the blank lines, the
   bullets and the bold all as you left them? *[rows 5, 6, 8-11, 14; N-11, N-12, N-16]*
2. **Sources, past page 2 (6 min).** In the Reader, type `00114` in the name filter to find *00114 Young
   papers.pdf* (Cambridge, Young papers, 1959). It is a 12-page document, each page a scan with its text beside it.
   Open it, move with Next to page 7 or later (the status line says "page 7 of 12"), and use Edit ▸ Copy Archive
   Link to This Page (⌥⌘L). Paste it into a note with Edit ▸ Paste as Source Block(s) (⇧⌘V). Is the thumbnail
   that page, and small enough for the note? Does Reveal in the Reader open the document at that page, not the
   first? Paste a second link, to another page of the same document: does each block show and reveal its own
   page? *[rows 17, 19; N-35, N-36]*
3. **Describe the note (7 min).** Open the inspector (⌥⌘I or the toolbar). Type a date at the precision you
   know (`1959`, or `March 1959`) and press Return; then try a decade (`1950s`) and empty the field. Add a
   sent-with date and an author, each by typing only. Add three tags under the note, one by typing part of an
   existing tag and taking the suggestion. Then change the date and the tags in the list itself
   (double-click the cell). Read what Round-up note says. Does anything still make you press a button to apply?
   Does the inspector feel like the right home for these fields? Right-click the row ▸ Reveal in Finder: do the
   Finder tags still match? *[rows 7, 15, 20-26, 32; N-04, N-17, N-19, N-20, N-21, N-22]*
4. **Organise (8 min).** Make three folders and drag one onto another to nest it, then drag it back out. Drag a
   note across the folder list slowly: does the highlighted folder always match where it will land? Delete a
   scratch note, then Edit ▸ Undo. Delete it again and find it in the sidebar's Trash; Put Back. Make a template
   with File ▸ New Template… (choose Notes), rename it in its list, assign it to a folder, and create a note from
   it in that folder: is the new item a note, not an extract? *[rows 30, 31, 34, 35, 38-43; N-26, N-28, N-29]*
5. **Find it again (10 min).** With five or more notes, narrow the list by a year and a tag. Clear only the year
   with its ⓧ, then everything with Clear All. Switch the scope control between All, Notes and Extracts. In
   View ▸ List Above Note, drag the divider up and down as far as you like. Then open Advanced Search (⇧⌥⌘F) and
   ask for notes with any of two tags, plus a date rule; watch the count change as you edit. Press Search, then
   Save as Smart Folder…. Right-click the smart folder ▸ Edit Smart Folder…, change one rule and save. Does the
   folder show what the rules say? *[rows 36, 37, 45, 47; N-07, N-32, N-50; W40.notes-advanced-search]*
6. **Shortcuts across the apps (3 min).** Without the mouse: ⌘N, ⌥⌘N, ⇧⌘O, ⌘F in a note, ⇧⌘C (Copy Link),
   ⌥⌘I. Then in the Reader, ⇧⌘O from a document window. Is any key you expected missing or different between
   the two apps? Can you tell the three apps apart by their icons in the Dock? *[rows 1, 3, 4]*
7. **Zotero (4 min).** As in session 1: Zotero running, "Allow other applications on this computer to communicate
   with Zotero" on, Zotero switched on in Notes' Settings (⌘,). Attach a `zotero://select/…` link for a real item
   (Note ▸ Attach Zotero Link…). Does the chip show a citation (author, title, date) rather than a code? Then
   Note ▸ Auto-fill from Zotero…: are the proposed fields right, and does Apply change only what you ticked? If
   it fails, copy the message onto the form. *[rows 50, 51; N-43, N-44]*

Session 1's extracts and links tasks went as promised and are not repeated. Try them if you have time.

## When you are done

- If you had notes in Notes' default store and want them back, File ▸ Choose Store Folder…, ⇧⌘G,
  `~/Library/Containers/com.archivenotes.app/Data/Library/Application Support/ArchiveNotes/Store`.
- Choose your real archive folder again in the Reader and in Notes, if you use them on it.
- Leave `notes-session-2/` where it is until your notes have been filed; after that it can be deleted with
  `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/notes-session-2`.
- Hand the form back however suits you: tell a session "file my Notes session notes" and paste them, or save
  this file with the form filled in.

## Notes form

Severity: **B** it stopped me or got something wrong · **A** annoying, slowed me down · **C** cosmetic · **?**
just a thought or a question.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |
| 4 | | | | |
| 5 | | | | |
| 6 | | | | |
| 7 | | | | |
| 8 | | | | |
| 9 | | | | |
| 10 | | | | |

**The known problems above:** which ones got in your way, and how much?

**Overall:** would you write a day's notes in Notes as it stands? If not, what is the one thing that stops you?

**Anything else:**

## For the session that files the notes

As for session 1 (`notes-1.md`, "For the session that files the notes"): a reproducible problem becomes a
`W40.fix-notes-<slug>` item with a severity and its ledger row goes to `broken`; a judgement call becomes one
Daemon Report question per note, or is recorded as decided if the owner decided it in the session; what cannot be
reproduced yet goes into `SUSPECTS.md` with "Raised: owner session notes-2"; Reader notes go to the Reader's queue.
A task that went as promised, with the owner watching, is runtime evidence: record it in the row's *Runtime
evidence* and move the row to `works`, citing the returned form. The rows waiting for this recheck
(`fixed-pending-recheck`) are N-07, N-11, N-12, N-16, N-22, N-26, N-35, N-44 and N-50. N-17, N-19, N-20, N-28 and
N-29 changed without a status change and also move on what the owner sees. Read the session store
(`notes-session-2/store`) with the app-hosted unit bundle or by hand, and never point a test that writes at it.
Keep the returned form as `verification/sessions/notes-2-returned.md`.
