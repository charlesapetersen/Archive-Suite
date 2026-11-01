# Reader guided session 1

About 45 minutes in Archive Reader, on a copy of 5,000 real PDFs from your collection. Work through the tasks the
way you would on a normal research day. Whenever something confuses you, feels slow, or gets something wrong,
write one line on the form at the end. Short notes are enough, and so is "I expected X". The next daemon session
turns each note into a reproduced bug, a design question for you, or a suspect (`verification/SUSPECTS.md`).

Prepared by `W40.g1` on 2026-10-15 and refreshed by `W40.g1-refresh` on 2026-10-31, after the fourteen Reader
fixes the first pack would have asked you to work around had shipped. The app's state is in
[`../reader.md`](../reader.md) (the feature ledger: nothing in it is `broken`) and in the two rehearsal reports,
[`../evidence/reader/W40.d7-at-size.md`](../evidence/reader/W40.d7-at-size.md) and
[`../evidence/reader/W40.d8-triage.md`](../evidence/reader/W40.d8-triage.md).

**What changed since the first pack.** The freezes on tag edits and sorts are gone (a tag edit redraws the list in
about 0.14 s at 116,000 files), and a several-word search with common words takes well under a second instead of
about 40. In a row's tag field, Space types a space and Return saves. The window works at its narrowest: the filter
bar wraps onto a second row and the Preview sheet fits inside the window. Clicking a Read cell now switches it, and
right-clicking it can clear the read state. Edit Tags… (⌘I) has a Sent-with date row; dates are no longer edited in
the list. Undo now survives a quit (the last 100 changes, from the app's change ledger). The Reader's writes no longer
leave a quarantine mark on your files. Long file names, the tag cloud's width, the tag editor's subject chips, the
selected-row colours, Find focus in the document window, and a selection hidden by a filter were also fixed. Options
has a new Appearance setting (System, Light, Dark), which a separate check covers; try it if you like, but it is not
a task here.

## Before you start (5 minutes, not counted)

1. **Make a fresh copy of the sample for this session.** The sample in
   `~/Library/Caches/ArchiveSuiteRehearsal/reader-sample/` is the one the daemon's rehearsals use and re-check,
   so work on a copy of it instead. The command makes APFS clones, so it is quick and takes almost no disk.
   Finder tags and dates come across unchanged.
   ```bash
   cd ~/Library/Caches/ArchiveSuiteRehearsal && rm -rf reader-session-1 && mkdir reader-session-1 && \
     cp -c -R -p "reader-sample/Archival Photos" "reader-sample/Archival Photos JPEGS" reader-session-1/
   ```
   The `rm -rf` removes the copy made on 2026-10-15 for the postponed session, if it is back on this Mac. It was
   never used, and its twin is in your OneDrive backup (moved 29 Oct). Nothing else is touched.
   None of this touches your real collection. The sample was copied out of it read-only, and the before/after
   check showed nothing there changed (`reader-sample/MANIFEST.txt`).
2. **Start the Reader:** `cd ~/Claude/"Archive Suite" && ./launch.sh reader`. This builds current `main` first if
   the app is out of date.
3. **Point it at the copy:** File ▸ Choose Archive Folder… (⇧⌘O). `~/Library` is hidden in the panel, so press
   ⇧⌘G and paste `~/Library/Caches/ArchiveSuiteRehearsal/reader-session-1`, then choose that folder. It is the one
   holding both `Archival Photos` and `Archival Photos JPEGS`. **Check the path before you change any tags.**
   The Reader keeps one archive folder, and that setting is shared with any other copy of the Reader on this Mac.
   Afterwards, see *When you are done*.
4. Keep this file open beside the app. Write your notes on the form at the bottom, in this file or on paper.

## Problems we already know about

Every Reader defect the first pack listed has been fixed. What is still known and open, with the tasks it touches:

- **The list does not show which files have a note**, and a note can be written only in Edit Tags… (⌘I), for one
  file at a time (ledger row R-30; no fix item, because it is how the app was built). Task 4. Tell us whether you
  missed it.
- **A slow several-word search may leave some hits without a snippet line.** Snippets stop after a quarter of a
  second so the search never stalls; every hit is still listed. Task 6.
- **While the sidebar slides open or shut at the narrowest window, the list's columns can lag by one point for a
  frame** (`W40.fix-reader-sidebar-slide-1pt`, cosmetic). You are unlikely to see it. No task depends on it.

## The tasks (45 minutes)

The minutes are a guide only. If one task is going badly, note it and move on. The ledger rows each task covers
are in brackets, for the session that files your notes. You don't need them.

1. **Open the collection (3 min).** After you choose the folder, watch the list fill and the OCR index build.
   That took about 10 seconds in the rehearsal. Open the library health popover. Can you tell what the app is
   doing, and when it has finished? Then drag the window to its narrowest once: is everything still in reach?
   *[R-01, R-02, R-12, R-13, R-40]*
2. **Find a box you know (5 min).** Use the sidebar folder tree, the file-name filter and the sort menu to get to
   one box or folder whose contents you remember, then sort it by document date. Is the order the one you would
   expect for those documents? Where two files share a name, can you tell them apart? *[R-05, R-06, R-10, R-14,
   R-15]*
3. **Read a document properly (7 min).** Open one in the document window. Page through its segment, zoom both the
   image and the text pages, switch to the JPEG original and back, and use Find… inside the document. Select a
   paragraph and copy it two ways, Copy and Copy Cleaned for Prose, then paste both into a text editor. Is the
   copied text what you wanted for a quotation? Also try the Preview sheet (Selection ▸ Preview). *[R-34, R-35,
   R-36, R-37, R-43]*
4. **Triage a run of unread files (8 min).** Go through at least ten unread files with Mark Read & Next Unread
   (⇧⌘M). Mark one back with ⌘U, and another by clicking its Read cell; right-click a Read cell once and look at
   what it offers. Use Select Document Run on a multi-page document. Flag one with Toggle Flag (⇧⌘F) and attach a
   note to it in Edit Tags… (⌘I). Does the next file it picks match the one you would read next? Is the pace
   comfortable for a long session? *[R-19, R-20, R-25, R-30, R-33]*
5. **Tag (8 min).** Give one file a subject and a quality with Edit Tags… (⌘I), then give three files a subject in
   one go. In the same sheet, give one file a Sent-with date. Type a two-word subject straight into a row's tag
   field and press Return. Try a subject that differs only in case from one that already exists and see what it
   tells you. Undo the last change with ⌘Z. Then type a few letters into the file-name filter and press ⌘Z there:
   what did it undo, the typing or a tag? Afterwards, are the tags what you meant, on the files you meant?
   *[R-21, R-22, R-23, R-24, R-27]*
6. **Search the OCR text (5 min).** Search (⌥⌘F) for a name or phrase you know is in that box: first one word,
   then two or three words. Do the hits and snippets show you where to look? Is anything you know is there
   missing? *[R-11]*
7. **Filters and a saved search (6 min).** Narrow the list by read state, by subject, and by quality. Open the tag
   cloud. Save the current search as a smart folder. Make one tag change you would want back, then quit (⌘Q),
   relaunch, and check that the smart folder is still there and the window comes back as you left it. Press ⌘Z
   once: does it undo the change from before you quit, and does it say what it undid?
   *[R-07, R-08, R-09, R-16, R-17, R-18, R-21, R-46]*
8. **Links (3 min).** Copy an archive link to a file, and with the document window open, Copy Archive Link to
   This Page. Paste them into Notes or a text editor and click them. Do they bring you back to the right place?
   *[R-31, R-44]*

## When you are done

- Choose your real archive folder again in File ▸ Choose Archive Folder… if you use the Reader on it.
  Otherwise the Reader keeps opening the session copy.
- Delete the smart folder you saved in task 7 (right-click it in the sidebar) if you don't want it kept.
- Leave `reader-session-1/` where it is until your notes have been filed. The daemon may want to look at the
  tags you wrote. After that it can be deleted: `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/reader-session-1`.
- Hand the form back however suits you: tell a session "file my Reader session notes" and paste them, or save
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

**Overall:** would you use the Reader for a real day of triage as it stands? If not, what is the one thing that
stops you?

**Anything else:**

## For the session that files the notes

For each line on the form:

- **Something went wrong or was slow** and it can be reproduced on the sample or a fixture: file a
  `W40.fix-reader-<slug>` item with the reproduction and a severity, and mark the ledger row `broken`. The
  severity follows phase rule 8's definitions (`S1` data loss or a write to the wrong file · `S2` a promised
  feature broken or unreachable · `S3` wrong but recoverable · `S4` cosmetic). The owner's letter informs it but
  does not set it.
- **A judgement call** ("I expected X"), where the app does what its guide says but that is not what the owner
  wants: put a question in the Daemon Report, one per note.
- **Not reproducible yet:** add a `SUSPECTS.md` entry with "Raised: owner session reader-1".
- Task 5's ⌘Z in the filter field tests suspect `S-001` (an open suspect, never run): a tag undone there confirms it
  and is filed as a fix item on an irreversible path; the typing undone clears it. Record either in `SUSPECTS.md`.
- A severity the owner gives to a known problem goes into that fix item's line, which may change its place in
  the queue.

Keep the returned form as `verification/sessions/reader-1-returned.md`. The next pack, `reader-2.md`, follows the
next batch of Reader fixes and replays the tasks that drew notes this time.
