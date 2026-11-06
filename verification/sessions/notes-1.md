# Notes guided session 1

About 45 minutes in Archive Notes, writing real notes from a copy of the same 5,000-PDF sample the Reader session
used. Work the way you would on a research day: read in the Reader, write and extract in Notes. Whenever something
confuses you, feels slow, or gets something wrong, write one line on the form at the end. Short notes are enough,
and so is "I expected X". The next daemon session turns each note into a reproduced bug, a design question for
you, or a suspect (`verification/SUSPECTS.md`).

Prepared by `W40.g2` on 2026-11-04. It was judged not time on 2026-10-15, because the Notes defects then queued would
have got in the way of these tasks. They, and the ones the screen-by-screen review found the next day, have all
shipped. The app's state is in [`../notes.md`](../notes.md),
the feature ledger, where nothing is `broken`. The machine runs behind it are
[`../evidence/notes/W40.d9-writing.md`](../evidence/notes/W40.d9-writing.md) (typing, autosave, quit),
[`../evidence/notes/W40.d10-integrations.md`](../evidence/notes/W40.d10-integrations.md) (a real Zotero, the real
Reader, links both ways) and
[`../evidence/notes/W40.notes-w7-gui-checks.md`](../evidence/notes/W40.notes-w7-gui-checks.md) (extracts and Jump
to Source).

**Is it time? Yes (judged 2026-11-04).** No Notes fix item is open. The work still queued for Notes is
`W47.ct-zotero`, which waits behind the containers design gate (`W47.ct-design-ok`), and the coverage hunt
`W40.e4`, which may find bugs but changes nothing you will see. The Reader fixes filed from your Reader session
today do not touch what you do in the Reader here: copying the two kinds of link and revealing a page. You said
in that session that both links work.

**What changed since the first judgement.** Paragraphs you type survive a reopen. Auto-fill from Zotero no longer
crashes. List rows and their text are no longer clipped or drawn across columns. Source chips are no longer
overdrawn by the file icon and sit on their own line. File ▸ Choose Store Folder… exists. A note with a damaged
block header no longer grows a line on every save. The window works at its narrowest. A failed image write, and a
save that fails as you close or quit, now tell you. Switching notes no longer shows the new note's header over the
old body. An edit made to the `.md` outside the app is no longer silently overwritten. The extract editor is no
longer squeezed. Jump to Source scrolls to the passage instead of stopping short. There is a new View ▸ List Above
Note layout and an Appearance setting (System, Light, Dark).

## Before you start (5 minutes, not counted)

1. **Make the session folder.** One command makes an APFS-clone copy of the Reader sample (quick, almost no disk)
   and an empty folder for a new Notes store beside it, not inside it:
   ```bash
   cd ~/Library/Caches/ArchiveSuiteRehearsal && rm -rf notes-session-1 && mkdir -p notes-session-1/store && \
     mkdir notes-session-1/archive && \
     cp -c -R -p "reader-sample/Archival Photos" "reader-sample/Archival Photos JPEGS" notes-session-1/archive/
   ```
   None of this touches your real collection. The sample was copied out of it read-only on 2026-11-04 and
   checked unchanged (`reader-sample/MANIFEST.txt`). If `reader-sample/` is not there, it has moved to the backup:
   rebuild it with `python3 ArchiveReader/scripts/rehearsal-sample.py make` (about 100 s), as the Reader session
   did.
2. **Start the Reader and point it at the copy.** `cd ~/Claude/"Archive Suite" && ./launch.sh reader`, then
   File ▸ Choose Archive Folder… (⇧⌘O), ⇧⌘G, paste `~/Library/Caches/ArchiveSuiteRehearsal/notes-session-1/archive`
   and choose it. Then select any file and copy one archive link (Selection ▸ Copy Archive Link(s), ⇧⌘L): the
   Reader gives the folder its identity file at the first archive-link copy, not when it opens the folder, and
   Notes needs that file to accept the folder. (Corrected after the session, W40.fix-suite-root-marker.)
3. **Start Notes:** `./launch.sh notes`.
4. **Point Notes at the new store:** File ▸ Choose Store Folder…, ⇧⌘G,
   `~/Library/Caches/ArchiveSuiteRehearsal/notes-session-1/store`. An empty folder becomes a new store. Notes asks
   to confirm, then quits; start it again with `./launch.sh notes`. The list should be empty.
5. **Point Notes at the archive:** File ▸ Choose Archive Folder…, the same `notes-session-1/archive` folder.
6. Keep this file open beside the apps and write on the form at the bottom, here or on paper.

## Problems we already know about

Only those that will stay open for a while:

- **A source block does not show the box and folder its document came from, and there is no Copy for Zotero
  export yet.** Both are `W47.ct-zotero`, which waits on the containers design you have not yet signed off
  (`W47.ct-design-ok`). Tasks 2 and 8. Say whether you missed them.
- **Three recent fixes have not yet been re-checked by a second session:** the styled editor's paragraphs and
  lists (N-12), Jump to Source (N-41) and Auto-fill from Zotero (N-44). Each passed its own tests. If one
  misbehaves, write it down like anything else.
- **The Reader's own fixes from today are queued** (where a copied link can be pasted, menus that follow the
  window, the Reader's own notes being removed, and the rest). Use the Reader here only to read and copy links,
  and leave notes about the Reader to its next session.

## The tasks (45 minutes)

The minutes are a guide only. If one task is going badly, note it and move on. The ledger rows each task covers
are in brackets, for the session that files your notes. You don't need them.

1. **A first note (5 min).** Make a note with ⌘N and give it a real title by renaming it in the list (Return or
   double-click). Type several paragraphs about something you are working on, with a heading, a bulleted list,
   bold and a link (Format menu or the toolbar). Switch to raw Markdown with ⌘/ and back. Quit with ⌘Q straight
   after typing, start Notes again and reopen the note: is everything there, laid out as you left it?
   *[N-11, N-12, N-13, N-14, N-16, N-48]*
2. **Sources from the Reader (8 min).** In the Reader, open a document you can write about. Copy an archive link
   to the file (right-click ▸ Copy Archive Link(s)), and in the document window, Document ▸ Copy Archive Link to
   This Page for a page you want to quote. In your note, paste each with Edit ▸ Paste as Source Block(s) (⇧⌘V),
   and write a line of commentary under each. Does the page block show the right page as a thumbnail? Open its
   Preview, then Reveal it in the Reader: does the Reader open that document at that page? Is the chip's label
   enough to tell you what the source is? *[N-03, N-34, N-35, N-36]*
3. **Describe the note (6 min).** In the inspector give it two subjects, a quality, and a date at the precision you
   actually know (a year, or a month), marked uncertain if it is. Add a sent-with date and an author typed by hand.
   If it is a round-up of several documents, turn on Round-up note and see what date it offers. Then right-click
   the row ▸ Reveal in Finder: do the Finder tags on the `.md` match what you set? If you deal with Old Style
   dates, try Settings (⌘,) ▸ Dates ▸ Show dates in other calendars on one item. *[N-04, N-17, N-18, N-19, N-20,
   N-21, N-22, N-23, N-30]*
4. **Extracts (7 min).** Select a passage in your note and use Extract ▸ Create Extract (⌥⌘E). Take a second
   passage from another note into the same extract with Append to Extract…. Copy a passage that includes a source
   chip and paste it into the extract. In the Extracts window, use the chip's Jump to Source: does it bring you to
   the passage in the Notes window? Does the extract's inspector tell you where its passages came from?
   *[N-07, N-39, N-40, N-41, N-42]*
5. **Organise (7 min).** Make a folder and a subfolder, and drag one to reorder or nest it. Put one note in two
   folders (⌥-drag, or right-click ▸ Add to Folder) and check its Locations in the inspector. Remove it from one
   folder, then delete a scratch note entirely: does the warning tell you what is about to happen, and is the note
   in the Trash afterwards? Make a template, assign it to a folder, and create a note from it in that folder.
   *[N-25, N-26, N-27, N-28, N-29]*
6. **Find it again (5 min).** With five or more notes, type a word from one into the search field, then narrow by
   quality, by subject and by year. Save that as a smart folder and check its count. Sort the list by date. Try
   View ▸ List Above Note and drag its divider. Is the note you wanted easy to get back to? *[N-08, N-09, N-31,
   N-32, N-33, N-49, N-50, N-51]*
7. **Links out and back (3 min).** Note ▸ Copy Link, paste it into Scrivener (or TextEdit) and click it, once with
   Notes showing another note and once with every Notes window closed. Does it bring you back to that note?
   *[N-45, N-46]*
8. **Zotero, if you use it on this Mac (4 min).** Zotero must be running, with Settings ▸ Advanced ▸ "Allow other
   applications on this computer to communicate with Zotero" on, and Zotero switched on in Notes' Settings (⌘,).
   Attach a `zotero://select/…` link for a real item to a note (Note ▸ Attach Zotero Link…, or Attach to note in
   the inspector). Does the chip show the citation you would expect, and open the item in Zotero? Then Note ▸
   Auto-fill from Zotero…: are the proposed fields right, and does Apply change only what you ticked? Skip this
   task if Zotero is not set up. *[N-43, N-44, N-47]*

## When you are done

- If you had notes in Notes' default store and want them back, File ▸ Choose Store Folder…, ⇧⌘G,
  `~/Library/Containers/com.archivenotes.app/Data/Library/Application Support/ArchiveNotes/Store`. Otherwise
  Notes keeps opening the session store.
- Choose your real archive folder again in the Reader (File ▸ Choose Archive Folder…) and in Notes, if you use
  them on it.
- Leave `notes-session-1/` where it is until your notes have been filed. The daemon may want to read the notes you
  wrote. After that it can be deleted: `rm -rf ~/Library/Caches/ArchiveSuiteRehearsal/notes-session-1`.
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

For each line on the form:

- **Something went wrong or was slow** and it can be reproduced on a scratch store or a fixture: file a
  `W40.fix-notes-<slug>` item with the reproduction and a severity, and mark the ledger row `broken`. The severity
  follows phase rule 8's definitions (`S1` data loss or a write to the wrong file · `S2` a promised feature broken
  or unreachable · `S3` wrong but recoverable · `S4` cosmetic). The owner's letter informs it but does not set it.
- **A judgement call** ("I expected X"), where the app does what its guide says but that is not what the owner
  wants: put a question in the Daemon Report, one per note. If the owner decides it during the session, as he did
  in the Reader session, record it as decided.
- **Not reproducible yet:** add a `SUSPECTS.md` entry with "Raised: owner session notes-1".
- **A note about the Reader** goes to the Reader's queue, not this one.
- A task that went as promised, with the owner watching, is runtime evidence for its rows. Record it in the row's
  *Runtime evidence* and move the row to `works`, citing the returned form. Rows in `fixed-pending-recheck` (N-12,
  N-41, N-44) move to `works` the same way.
- Read the session store (`notes-session-1/store`) with the app-hosted unit bundle or by hand. Never point a test
  that writes at it.

Keep the returned form as `verification/sessions/notes-1-returned.md`. The next pack, `notes-2.md`, follows the
next batch of Notes fixes and replays the tasks that drew notes this time.
