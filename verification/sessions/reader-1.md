# Reader guided session 1

About 45 minutes in Archive Reader, on a copy of 5,000 real PDFs from your collection. Work through the tasks the
way you would on a normal research day. Whenever something confuses you, feels slow, or gets something wrong,
write one line on the form at the end. Short notes are enough, and so is "I expected X". The next daemon session
turns each note into a reproduced bug, a design question for you, or a suspect (`verification/SUSPECTS.md`).

Prepared by `W40.g1` on 2026-10-15, at the commit that added this file. The app's state at that point is in
[`../reader.md`](../reader.md) (the feature ledger) and in the two rehearsal reports,
[`../evidence/reader/W40.d7-at-size.md`](../evidence/reader/W40.d7-at-size.md) and
[`../evidence/reader/W40.d8-triage.md`](../evidence/reader/W40.d8-triage.md).

## Before you start (5 minutes, not counted)

1. **Make a fresh copy of the sample for this session.** The sample in
   `~/Library/Caches/ArchiveSuiteRehearsal/reader-sample/` is the one the daemon's rehearsals use and re-check,
   so work on a copy of it instead. The command makes APFS clones, so it is quick and takes almost no disk.
   Finder tags and dates come across unchanged.
   ```bash
   cd ~/Library/Caches/ArchiveSuiteRehearsal && mkdir reader-session-1 && \
     cp -c -R -p "reader-sample/Archival Photos" "reader-sample/Archival Photos JPEGS" reader-session-1/
   ```
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

Each of these has a reproduction and a fix item filed. If you hit one, you don't need to describe it, but **do
write how much it got in your way**. That tells us which to fix first.

- **Tag edits and sort changes freeze the window for one to five seconds** at this size
  (`W40.fix-reader-list-recompute-at-size`).
- **A search of several words that includes common words can take about 40 seconds**, and every later search
  waits behind it (`W40.fix-reader-fts-snippet-stall`). Single words and rare words are fast.
- **In the inline tag field in a row, Space opens Preview and Return does not save**. You have to click out of
  the field to save (`W40.fix-reader-inline-keys`).
- **At its narrowest the window cuts off the sidebar and the filter bar**, and the Preview sheet is larger than
  the window (`W40.fix-reader-narrow-window`, `W40.fix-reader-preview-sheet-oversize`). Widen the window if that
  happens.
- **Clicking the Read column does nothing yet**, and dates cannot be edited inside the list. You decided on
  2026-10-12 to wire the first and move date editing into Edit Tags (`W40.fix-reader-read-toggle`,
  `W40.fix-reader-sent-with-date`). Use ⌘R / ⌘U and Edit Tags… (⌘I) for now.

## The tasks (45 minutes)

The minutes are a guide only. If one task is going badly, note it and move on. The ledger rows each task covers
are in brackets, for the session that files your notes. You don't need them.

1. **Open the collection (3 min).** After you choose the folder, watch the list fill and the OCR index build.
   That took about 10 seconds in the rehearsal. Open the library health popover. Can you tell what the app is
   doing, and when it has finished? *[R-01, R-02, R-12, R-40]*
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
   (⇧⌘M). Mark one back with ⌘U. Use Select Document Run on a multi-page document. Flag one with Toggle Flag (⇧⌘F) and attach a note to it.
   Does the next file it picks match the one you would read next? Is the pace comfortable for a long session?
   *[R-19, R-20, R-30, R-33]*
5. **Tag (8 min).** Give one file a subject and a quality with Edit Tags… (⌘I), then give three files a subject in
   one go. Type a subject straight into a row's tag field. Try a subject that differs only in case from one that
   already exists and see what it tells you. Undo the last change with ⌘Z. Afterwards, are the tags what you
   meant, on the files you meant? *[R-21, R-22, R-23, R-24, R-27]*
6. **Search the OCR text (5 min).** Search (⌥⌘F) for a name or phrase you know is in that box: first one word,
   then two or three words. Do the hits and snippets show you where to look? Is anything you know is there
   missing? *[R-11]*
7. **Filters and a saved search (6 min).** Narrow the list by read state, by subject, and by quality. Open the tag
   cloud. Save the current search as a smart folder. Quit (⌘Q), relaunch, and check that the smart folder is
   still there and the window comes back as you left it. *[R-07, R-08, R-09, R-16, R-17, R-18]*
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
- A severity the owner gives to a known problem goes into that fix item's line, which may change its place in
  the queue.

Keep the returned form as `verification/sessions/reader-1-returned.md`. The next pack, `reader-2.md`, follows the
next batch of Reader fixes and replays the tasks that drew notes this time.
