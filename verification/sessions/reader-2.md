# Reader guided session 2

About 45 minutes in Archive Reader, going back over the tasks that drew notes in session 1
([`reader-1-returned.md`](reader-1-returned.md)), on a fresh copy of the same 5,000-PDF sample. All eight tasks
drew notes, so all eight come back, each aimed at what changed. Work as you would on a research day. Whenever
something confuses you, feels slow, or gets something wrong, write one line on the form at the end. Short notes
are enough, and so is "I expected X". The next daemon session turns each note into a reproduced bug, a design
question for you, or a suspect (`verification/SUSPECTS.md`).

Prepared by `W40.g1-reader-2` on 2026-11-06.

**Is it time? Yes (judged 2026-11-06).** Every one of the 38 rows you filed in session 1 has a fix that has
shipped, the last of them (Advanced Search, the scroll position after a relaunch, the title bar) this morning. No
Reader fix item is open. The Reader work still queued does not touch these tasks for a while: the Container column
and its inspector (`W47.ct-reader-view`, `W47.ct-reader-edit`) wait for your sign-off on the containers design, and
flagging poor OCR for the Processor (`W44.reocr-reader`) waits for the processing review. Before handing this over
the whole Reader UI test suite was run in the off-screen VM at today's `main`; the result is under *Checked before
handover* at the end.

**What changed since session 1** (your row numbers in brackets):

- **The list.** At the narrowest window the Read column stays in view: File name and File tags give up their
  width first. Every column header has a tooltip. ⚑ (Flag) and ⚠︎ (Needs attention) sort, from the header or
  Sort & Filter. A **Columns** chip at the end of the filter bar lists every column by name and turns each on or
  off. Provenance is renamed **Capture marker** and stays hidden, greyed "no file has one yet", while no file has
  a page-2 capture marker, which is every file in a collection made before these apps. [1, 3, 4, 5, 6, 22]
- **Health counts.** "Needs attention" and "ambiguous dates" are no longer always in the filter bar. The status
  bar's stethoscope fills in and takes the warning colour while either count is above zero; the Library health
  popover lists both, each with a Show button that turns its filter on. [2]
- **The filter bar** has three rows: the filters, then the file-name and OCR-text fields on their own row and a
  size larger, then, only while something applies, **In effect:** with a removable chip for each filter, search,
  folder or smart folder. An empty list names what is hiding the rows ("The file-name filter "smith" hides every
  file in the folder "Jones"") with a button to clear each. [7, 8]
- **The document window.** ⌘+ / ⌘− zoom the focused pane (⌘0 fits it), and on a one-page PDF they now change the
  text size, which before changed nothing. The toolbar's two pairs are labelled apart: Zoom Out / In Image
  (magnifiers) and Smaller / Larger Text (text-size glyphs). The Fit arrows are gone; Reset Zoom (⌥⌘0) is live only
  when something is zoomed. A **PDF / JPEG** switch in the toolbar shows which image is on the left and switches
  it; on a file with no JPEG it is greyed and its tooltip says why. [9, 10, 11, 13, 18]
- **Find (⌘F) searches both pages at once.** A word on the image page and the text page is one hit, highlighted in
  both, and Find Next moves both. On the JPEG original a box is drawn where the word sits on the PDF's image
  page. [12]
- **Menus follow the window in front.** With a document window in front, Hide Sidebar and Hide Tag Cloud are not
  listed, and the Tags menu acts on the file that window shows (Mark Read/Unread, Edit Info…, Toggle Flag, Mark
  Read & Next Unread, which moves the window to the next unread file). [14, 20]
- **Copying.** Copy Cleaned for Prose (⌥⌘C) and Copy Archive Link to This Page (now ⌥⌘L) are under Edit, beside
  Copy. Cleaned for Prose now starts a new paragraph where the OCR left no blank line but the page shows one (a
  wider gap, a first-line indent, or a short line ending in a full stop); Options ▸ Copying text can switch that
  off. It has not yet met your real pages: this session is where it does. [15, 16, 19]
- **Preview** (Space or ⌘Y): the image of the selected file is drawn ahead in the background while you are on the
  list, so it should appear with the text rather than about a fifth of a second after. [17]
- **Undo and Redo.** Tags ▸ Redo Tag Change (⇧⌘Z) brings back what Undo took, until you make a new change, and
  it survives a quit as Undo does. With the caret in any text field, ⌘Z and ⇧⌘Z undo and redo the typing and
  leave your tags alone. At launch the list has the keyboard, so ⌘Z works before any click. [21, 32, 37]
- **Flag.** Toggle Flag (⇧⌘F) shows ⚑ in the row at once. [23]
- **The Reader's own notes are gone**, as you decided; the flag stays. [24, 25]
- **Tags.** The app says "tags" everywhere. Edit Tags… is now **Edit Info…** (⌘I, the Mac's Get Info key), since
  it also edits quality, the dates and the flag. Its tag field autocompletes and keeps the keyboard: Return or a
  comma adds a tag, Tab takes the suggestion. In a row's tag field, Return adds the tag and keeps the field open
  for the next, and a space ends an autocompletion where you typed it. [27, 28, 29, 31, 36]
- **Case.** Tags that differ only in case are one tag, across all three apps. A tag you add takes the spelling the
  collection already uses, and Edit Info says so ("Added as "Lincoln", the existing spelling of this tag").
  Renaming a tag to a new case re-spells it everywhere. [30]
- **No Set or Clear buttons.** Edit Info's year, day and Sent-with date apply on Return, on leaving the field or on
  Done; emptying a field clears it. The Uncertain markers are checkboxes. (A suite rule from your Notes session.)
- **Tag cloud.** A stepper under "Tags in view" hides tags on fewer than N of the files in view, remembered between
  launches. [26]
- **Advanced Search** (Selection ▸ Advanced Search…, ⇧⌥⌘F, or Advanced… beside the OCR box): Finder-style rule
  rows, as you chose, starting with OCR text, Tags and Date. All or any of the rules, nested groups, "has none of
  these tags", dates by year, month, day or decade, folders, quality, read state, flag. Save as Smart Folder…
  keeps it; Edit Smart Folder… (right-click it in the sidebar) opens it again. Smart folders are now stored this
  way, so saving the filter bar saves exactly what the list shows. [33]
- **Search snippets.** A hit the first pass left without a snippet gets one as its row comes into view. In the
  at-size run every hit with OCR text got its line; the hits still without one are photographs, which have no
  text. (Session 1's known problem, which you asked to have fixed.)
- **Shortcuts across the suite** were checked: Show/Hide Sidebar is now ⌃⌘S (the Mac's) and Show/Hide Tag Cloud
  ⌃⌘T; ⌘F in the list window goes to Search OCR text; ⇧⌘O works from any Reader window. The full map is in
  `ArchiveReader/REFERENCE.md` §Keyboard map.
- **Title bar:** one even background behind "Archive Reader". This one could not be seen on macOS 27 (the test
  machine runs 26, whose title bar is opaque), so your screen is the check. [34]
- **Relaunch** brings the list back to the rows you were looking at, not only the folder. [35]
- **Links.** After Copy Archive Link(s), the status line says where a link opens: Archive Notes, Apple Notes, Mail
  or Messages (paste and click), or Safari's address bar. [38]

## Before you start (5 minutes, not counted)

1. **Make a fresh copy of the sample for this session.** APFS clones, so it is quick and takes almost no disk;
   Finder tags and dates come across unchanged.
   ```bash
   cd ~/Library/Caches/ArchiveSuiteRehearsal && rm -rf reader-session-2 && mkdir reader-session-2 && \
     cp -c -R -p "reader-sample/Archival Photos" "reader-sample/Archival Photos JPEGS" reader-session-2/
   ```
   None of this touches your real collection. The sample was copied out of it read-only on 2026-11-04, and the
   before/after check showed nothing there changed (`reader-sample/MANIFEST.txt`). If `reader-sample/` is not
   there, it has moved to the backup: rebuild it with
   `cd ~/Claude/"Archive Suite" && python3 ArchiveReader/scripts/rehearsal-sample.py make` (about 100 s), then
   run the copy command.
2. **Start the Reader:** `cd ~/Claude/"Archive Suite" && ./launch.sh reader`. This builds current `main` first if
   the app is out of date.
3. **Point it at the copy:** File ▸ Choose Archive Folder… (⇧⌘O), ⇧⌘G, paste
   `~/Library/Caches/ArchiveSuiteRehearsal/reader-session-2`, and choose that folder (the one holding both
   `Archival Photos` and `Archival Photos JPEGS`). **Check the path before you change any tags.** The setting is
   shared with any other copy of the Reader on this Mac; see *When you are done*.
4. Keep this file open beside the app and write on the form at the bottom, here or on paper.

## Problems we already know about

Only those that will stay open for a while, or are limits of a fix left on purpose:

- **Find in both pages pairs hits by order.** The third match on the image page is paired with the third on the
  text page, which is right when both pages read the same words in the same order and can be off where the OCR
  differs. An image page with no text layer gets no highlight, and the plain-text pane of a one-page PDF
  highlights its hits but does not scroll to them. Task 3.
- **Preview draws only a document's first page ahead.** Later pages of a multi-page document load as before.
  Task 3.
- **Undo from the document window undoes the newest change**, which may be on another file; the status line names
  the file. Task 4.
- **After typing in the file-name filter, a tag change made with the mouse leaves the caret in the filter**, so ⌘Z
  there undoes the typing. The toolbar's Undo still undoes the tag. Task 5.
- **Advanced Search gives snippets to its first 300 hits only**; the OCR box fills in the rest as you scroll, as
  above, but Advanced Search does not yet. Task 6.
- **At the narrowest window, a wider sidebar, the tag cloud or an extra column still needs a sideways scroll.** The
  default columns fit. Task 1.
- **No Container column yet** (which box and folder a file belongs to): `W47.ct-reader-view`, after the containers
  design. Capture marker is not it: that column names the kind of capture page, and is hidden in this sample.

## The tasks (45 minutes)

The minutes are a guide. If one task is going badly, note it and move on. The brackets give session 1's rows and
the ledger rows each task covers, for the session that files your notes. You don't need them.

1. **Open the collection (4 min).** Choose the folder and watch the list fill. Look at the status bar's stethoscope
   while the OCR index builds, and open the Library health popover: are the counts there when you want them, and
   out of the way when you don't? Hover over the ⚑ and ⚠︎ column headers, then sort by each. Use the **Columns**
   chip to turn a column off and back on. Drag the window to its narrowest: is the Read column still in view?
   *[rows 1-6, 22; R-01, R-02, R-12, R-13, R-40]*
2. **Find a box you know (5 min).** As in session 1: the sidebar tree, the file-name filter and a sort by document
   date. Then do what caught you last time: search a name, and click another person's folder in the tree. Is it
   plain what is still in effect? Remove one chip from the **In effect** row. Are the two search fields big enough
   now? *[rows 7, 8; R-05, R-06, R-10, R-14, R-15]*
3. **Read a document properly (9 min).** Type `00114` in the file-name filter and open *00114 Young papers.pdf*
   (12 pages, each a scan with its text beside it). Page through it, then press ⌘F and search a word that appears
   on several pages: is each hit lit on both pages, and does Find Next move both? Then open a one-page document
   (most of the sample) and change its text size with ⌘+ and ⌘−, and with the toolbar's Smaller / Larger Text.
   Switch to the JPEG original with the toolbar's PDF / JPEG switch, search again there, and switch back. Look at
   the View menu while the document window is in front. Select two or three paragraphs of a typed letter, use
   Edit ▸ Copy Cleaned for Prose (⌥⌘C), and paste into a text editor: are the paragraph breaks where the page has
   them, and only there? Then close the window, select a file in the list and press Space: does the image arrive
   with the text? *[rows 9-19; R-34, R-35, R-36, R-37, R-43]*
4. **Triage a run of unread files (7 min).** Go through ten or more unread files with Mark Read & Next Unread
   (⇧⌘M), in the list and once from a document window, where the Tags menu now works. Flag one with ⇧⌘F: does ⚑
   appear at once? Mark one back to unread, Undo it (⌘Z), then Redo (⇧⌘Z). Is the pace comfortable for a long
   session? *[rows 20, 21, 23, 24; R-19, R-20, R-21, R-25, R-30, R-33]*
5. **Tag (8 min).** Open Edit Info… (⌘I) on one file and add three tags without touching the mouse, one of them
   by typing part of an existing tag and pressing Tab. Give it a quality and a Sent-with date, and empty the date
   again. Then give three files a tag in one go. In a row's tag field, add two tags in a row, one of them a
   two-word tag that starts like an existing tag (type the first word and a space, and keep going). Add a tag that
   differs only in case from one that exists: what does it tell you, and which spelling do the files get? Set the
   tag cloud's stepper so only the commoner tags show. Then type a few letters into the file-name filter and press
   ⌘Z: what did it undo? Afterwards, are the tags what you meant, on the files you meant?
   *[rows 26-32, 36; R-18, R-21, R-22, R-23, R-24, R-27]*
6. **Search the OCR text (6 min).** Search (⌥⌘F) for a name or phrase you know is in that box, first one word, then
   two or three. Scroll down the hits: does every one with text have its snippet? Then open Advanced Search
   (⇧⌥⌘F) and build something the filter bar could not do: for example a phrase in the OCR text, a date range, and
   "has none of these tags". Does the count follow as you edit? Save it as a smart folder, then reopen it with
   Edit Smart Folder… and change one rule. *[row 33 and session 1's snippets note; R-11, R-16]*
7. **Filters, quitting and coming back (4 min).** Scroll well down a long folder or smart folder so a particular
   row is at the top. Make one tag change you would want back. Quit (⌘Q) and relaunch. Does the list come back at
   that row? Press ⌘Z straight away, before clicking anything: does it undo the change from before you quit, and
   say what it undid? Look at the title bar behind "Archive Reader" in light and dark (Options ▸ Appearance): one
   even background? *[rows 34, 35, 37; R-07, R-08, R-09, R-16, R-17, R-21, R-46, R-48]*
8. **Links (2 min).** Copy an archive link to a file (⇧⌘L) and read the status line. Open a document, go to a later
   page and press ⌥⌘L. Paste both where the status line suggests and click them: do they bring you back to the
   right place? *[row 38; R-31, R-44]*

## When you are done

- Choose your real archive folder again in File ▸ Choose Archive Folder… if you use the Reader on it. Otherwise the
  Reader keeps opening the session copy.
- Delete the smart folder you saved in task 6 (right-click it in the sidebar) if you don't want it kept.
- Leave `reader-session-2/` where it is until your notes have been filed; the filing session may want to look at
  the tags you wrote. After that it is deleted (your call from session 1):
  `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/reader-session-2`.
- Hand the form back however suits you: tell a session "file my Reader session notes" and paste them, or save this
  file with the form filled in.

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

**Overall:** would you use the Reader for a real day of triage as it stands? If not, what is the one thing that
stops you?

**Anything else:**

## For the session that files the notes

As for session 1 (`reader-1.md`, "For the session that files the notes"): a reproducible problem becomes a
`W40.fix-reader-<slug>` item with a severity and its ledger row goes to `broken`; a judgement call becomes one Daemon
Report question per note, or is recorded as decided if the owner decided it in the session; what cannot be
reproduced yet goes into `SUSPECTS.md` with "Raised: owner session reader-2". A task that went as promised, with the
owner watching, is runtime evidence: record it in the row's *Runtime evidence* and move the row to `works`, citing
the returned form. The rows waiting for this recheck (`fixed-pending-recheck`) are R-11, R-13, R-20, R-21, R-23, R-45
and R-46 (R-45 and R-46, the Core Directive and the audit ledger, move only on what the tag writes in task 5 left on
disk: read the session copy's tags and ledger with the app-hosted unit bundle or by hand, never with a test that
writes). Three fixes were never seen on the owner's own pages or Mac and are checked here first: Copy Cleaned for
Prose's paragraph breaks on real OCR (task 3), the title bar on macOS 27 (task 7) and the preview's image speed on
real scans (task 3). Keep the returned form as `verification/sessions/reader-2-returned.md`, then delete
`reader-session-2/` (the owner's call, 2026-11-04).

## Checked before handover

The whole `ArchiveReaderUITests` suite ran in the off-screen VM on 2026-11-06 at `main` `7b504478`: 78 tests
passed, 10 opt-in ones (the visual tour, the corrupt-index fixture) were skipped as usual, and one failed.
`ViewerUITests.testFindCommandsAreDisabledInThePreviewSheetOnly` still expected Find… to be greyed in the list
window, which the shortcuts check made Search OCR text on purpose that morning. So the test was out of date and the
app was fine. The test now expects Find… to be live there, with Find Next and Find Previous off, and all 18
ViewerUITests passed in the VM.
