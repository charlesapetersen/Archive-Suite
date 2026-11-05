# Notes guided session 1 — returned form

Run 2026-11-05 as an interactive walkthrough in an owner-started Claude session; the session wrote down the
owner's words as he gave them. Pack: [`notes-1.md`](notes-1.md). Builds: Reader and Notes Debug at `origin/main`
2026-11-05 morning. Store and archive: `~/Library/Caches/ArchiveSuiteRehearsal/notes-session-1/`.

Severity: **B** stopped me or got something wrong · **A** annoying, slowed me down · **C** cosmetic · **?** a thought.

| # | Task | What I expected | What happened | B / A / C / ? |
|---|---|---|---|---|
| 1 | Setup (Reader) | ⇧⌘O in the Reader opens Choose Archive Folder… | "⇧⌘O does nothing." (Reader's command is disabled when `nav == nil`; Notes also binds ⇧⌘O, to Numbered List.) Reader note, for the Reader's queue | B |
| 2 | Setup (Notes) | Choosing `notes-session-1/archive` in Notes works | "“archive” is not an Archive Reader folder. Choose the archive folder Reader itself opens." The Reader had not yet claimed the folder because of row 1; the message does not say that the Reader must open it first | ? |
| 2a | Setup (Notes) | After the Reader shows the files, Notes accepts the same folder | Same refusal again, with the Reader displaying the folder. Cause found in the session: the Reader writes `.archive-suite-root.json` only at the first Copy Archive Link (`RootFolderStore.prepareMarkerForLinkCopy`), not when a folder is chosen, so the pack's setup step 2 is wrong and Notes' message sends the user to a step that does not help. Workaround used: copy one archive link in the Reader first | B |
| 3 | All apps | — | "We should plan probably to check / add / confirm keystroke bindings across all the apps." A request for a shortcut audit across Reader, Notes and Processor | ? |
| 4 | All apps | Each app recognisable by its icon | "Notes and Reader have the same App icons, which is confusing. We should differentiate, and maybe make new icons for all three apps." | A |
| 5 | 1 | ⌘N makes a note | "Command–N is not in the menu bar and does nothing." Used the New Note button at the upper right instead | B |
| 6 | 1 | Click the title in the note to edit it | "Clicking the title in the note does nothing." Renaming works by double-clicking the row in the list | A |
| 7 | 1 | Edit the date and the tags in the list, as the title can be | "I can't seem to edit the date directly in the file navigation list. I also can't seem to edit the tags directly in the file navigation list." | ? |
| 8 | 1 | Return adds blank lines; Backspace joins lines | "In the note editor, I can't add multiple new lines. When I type backspace, I can't delete a newline." It went away, then came back after deselecting and reselecting the note. (N-12, fixed-pending-recheck) | B |
| 9 | 1 | The renamed title stays in the list | "After I give the note a title, the title appears in the file navigation list. But if I then click away and deselect the note, the title disappears." On disk the `.md` keeps `title: Daily Schedule`, so the list loses it, not the file | B |
| 10 | 1 | Bulleted List makes a bullet | "Clicking the Bulleted List toggle seems to do nothing — nothing appears." The newline problem of row 8 follows it. (N-12) | B |
| 11 | 1 | Bold text stays bold | "I added some bold text, clicked away from the note, then clicked back to it. One of the bold text lines then appears in raw markdown as \"**Day**\"." On disk it was saved as the escaped `\*\*Day \*\*`: the bold run ended in a space, so it saved as literal asterisks, and reopening shows them as text | B |
| 12 | 1 | ⌘/ switches to raw Markdown and back | "This works." | — |
| 13 | 1 | ⌘Q straight after typing, relaunch, reopen: all there | "Yes, intact." | — |
| 14 | 1 | After renaming in the list, the note stays selected | "Typing the title of a note and pressing return deselects the note. The note should stay selected." | A |
| 15 | 1 | A visible way to set the note's date | "I don't see a way to edit a note date." (The date is in the inspector, task 3; the owner had not found it from the note or the list) | A |
| 16 | 2 (Reader) | PDF / JPEG switch keeps the view | "In reader, when switching between PDF and JPEG, we should keep the same zoom level and if possible keep the same region visible." Reader note, for the Reader's queue | ? |
| 17 | 2 | Reveal opens the Reader at the linked page | "I don't have any multi-page documents in Reader so it's hard to tell if this is working correctly. But it seems to work." The sample's PDFs are the 2-page image-and-text format, so a page link was not tested on a longer document | ? |
| 18 | 2 | Chip labels say what the source is | "The labels are good." | — |
| 19 | 2 | Source images in the note sized for reading the note | "The images in the note itself should be smaller — they're currently as big as the preview." | A |
| 20 | 3 | A way to open the inspector, in the menu bar | "I don't see how to open the inspector. It's not in the menu bar." There is no inspector panel: the fields are a "Details" disclosure above the editor (`NotesBrowserView.DetailPane.metadataToggle`), with no menu item or shortcut. The pack and the guide say "inspector"; the app says "Details" | A |
| 21 | 3 | The note's fields in a Mac-style inspector or sheet | "I think I'd rather have an Inspector or else a pop-up as in Reader. I don't like how Details takes up screen space. It doesn't feel Mac-like." A design call: replace the Details strip with an inspector panel or a sheet like the Reader's Edit Info… (⌘I) | ? |
| 22 | 3 | Typing a date sets it, at the precision typed | "I shouldn't have to click 'Set' or 'Clear' for the Year. I shouldn't have to choose 'Decade', 'Year', 'Month', 'Day' for granularity — this should be auto-detected." | A |
| 23 | 3 | Tags edited below the note | "'Tags' should appear in a separate editing pane below the note, not in the Inspector or in Details." A design call, alongside row 21 | ? |
| 24 | 3 | Round-up note explains itself | "It's not clear what 'Round-up note' does." | A |
| 25 | All apps | Fields apply as typed, with no Set or Clear buttons | "In general we shouldn't use buttons for 'Set' and 'Clear'. Apply across all three apps." A rule for Reader, Notes and Processor | ? |
| 26 | 3 | Tags autocomplete, and Return adds one | "Tags don't autocomplete. Pressing return should add them — we should not use an 'Add' button." (The Reader got autocompleting tag entry with Return on 2026-11-05, W40.fix-reader-tag-entry; Notes has its own field) | A |
| 27 | 3 | Finder tags on the `.md` match the note's | "The tags matched in Finder, yes." | — |
| 28 | 4 | Create, Append, paste a chip, Jump to Source (N-41, fixed-pending-recheck) | "Everything seems to work." | — |
| 29 | 4 | The extract says where its passages came from | Details ▸ Sources names both notes with their passage counts: "Yes, both." | — |
| 30 | 5 | Drag a folder onto another to nest it | "I can't drag one folder into the other to nest it. Reordering works." | B |
| 31 | 5 | The folder under the pointer highlights as a drop target | "Dragging a note to a folder: the folder becomes blue somewhat randomly depending on where the mouse pointer is." | A |
| 32 | 5 | Locations shown out of the way | "Folder locations should appear in the inspector, not in the main window — it takes up too much room." A design call, with rows 21 and 23 | ? |
| 33 | 5 | Remove a note from one folder | "This worked." | — |
| 34 | 5 | Edit ▸ Undo brings back a deleted note | "I deleted a note. I tried to undo this but undo didn't work. It should work." | A |
| 35 | 5 | A visible way to make a template | "I don't see how to create a template." It exists only as the sidebar's "Templates" row and its + button (`TemplatesManagerView`); no menu item | A |
| 36 | 5 | The menu bar scope reads All, Notes, Extracts | "In the menu bar, we currently have: 'Notes', 'Extracts', 'Both'. This should be 'All', 'Notes', 'Extracts'." | C |
| 37 | 6 | No All/Any beside Tag… in the filter bar | "We don't need the 'All' and 'Any' options next to 'Tag…'. That should be available in Advanced Search, which we'll also presumably need to build." Matches the Reader's call of 2026-11-04 (Advanced Search as rule rows; the filter bar keeps no NOT) | ? |
| 38 | 5 | The toolbar's New button offers a new note | "If I click to make a New Note in the upper right, I am only given an option for 'New Extract'." The button's item follows the window's kind (`kindLabel`), so in the Extracts window it offers only extracts, with no visible sign why. Also row 5: ⌘N is bound only inside this toolbar menu, which is why the menu bar has no New Note | A |
| 39 | 5 | In the Notes window, New makes a note | "I am currently in the Notes window and it still says 'New Extract'." The label is `nav.windowKind == .extract`, so this window's kind is extract while the owner reads it as the Notes window: the window's kind is either wrong or not shown | B |
| 40 | 5 | Delete warns, then the note can be found in a Trash | "The delete warning appeared. I don't see an option to view the trash." A deleted note's folder goes to the Finder Trash (`NoteStore.delete`, `trashItem`); Notes has no Trash view or Put Back | A |
| 41 | 5 | A clear way to make a template | "We need a clearer way for a user to make a Template." (With row 35) | A |
| 42 | 5 | Rename a template in its list, as a note can be | "I can't retitle the Template in the file navigation list." (Rename… is only in the row's context menu) | A |
| 43 | 5 | A new template makes the kind of item asked for | "The template also starts an Extract, though I didn't specify this." Likely the same window-kind fault as rows 38-39: the new template takes the window's kind | B |
| 44 | 5 | Assign a template to a folder and create a note from it there | "Yes, it worked." | — |
| 45 | 6 | List Above Note's divider moves over a wide range | "I should be able to drag the divider more up and down." | A |
| 46 | 6 | Search, narrow, save a smart folder, sort by date | "Otherwise seems to work." | — |
| 47 | 6 | One step clears the date filter, and one clears every filter | "There should be a simple way to clear the date filtering. And to clear all filters." | A |
| 48 | 7 | Copy Link, paste elsewhere, click: back to the note, with another note showing and with no window open | "The links work." | — |
| 49 | 8 | Attach a Zotero link to a note | "This worked." | — |
| 50 | 8 | The chip shows a citation | "I see a Zotero code (\"GL2HWVUW\"). It would be better if I actually saw a citation, such as author/title/date." Likely the same failed fetch as row 51, so the chip falls back to the item key | A |
| 51 | 8 | Auto-fill proposes Zotero's fields (N-44, fixed-pending-recheck) | "Zotero metadata could not be fetched. The operation couldn't be completed. (ArchiveNotes.ZoteroClient.ClientError error 0.)" Error 0 is `.unavailable`. From the session's shell at the same time, Zotero's local API at 127.0.0.1:23119 answered 200 (`/api/users/0/items?limit=1`), so Zotero was reachable and Notes was not reaching it. The message also shows a raw error code | B |

**Tasks that went as promised:**

**The known problems:**

**Overall:** Would you write a day's notes in Notes as it stands? "Not yet." And: "All of the problems I've filed here should be fixed. Treat none as minor. These problems are much more severe than in Reader."

**For the filing session (owner's instruction, 2026-11-05):** every row above with a problem or a request is to be fixed; none is deferred as minor or cosmetic, row 36's C included. Rows marked "Reader note" go to the Reader's queue. Rows 3 (shortcut audit), 4 (new icons for all three apps) and 25 (no Set or Clear buttons) are cross-app items. Rows 21, 23 and 32 (where the note's fields, tags and locations go) are one design question for the owner. Rows 12, 13, 18, 27-29, 33, 44, 46, 48 and 49 are runtime evidence; N-41 (Jump to Source) passed and moves to works; N-12 (rows 8, 10, 11) and N-44 (row 51) failed their recheck.

**Anything else:**
