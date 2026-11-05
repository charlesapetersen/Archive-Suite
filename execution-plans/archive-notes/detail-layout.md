# Where a note's fields, tags and locations go — design for the owner

`W40.notes-detail-layout-design` (2026-11-05). Answers the owner's Notes guided session 1
(`verification/sessions/notes-1-returned.md`, rows 7, 20, 21, 23, 32). The build is
`W40.notes-detail-layout`, held by `W40.notes-detail-layout-owner-ok`. Delete this file when the build ships.

## What the owner said

- Row 20: "I don't see how to open the inspector. It's not in the menu bar."
- Row 21: "I'd rather have an Inspector or else a pop-up as in Reader. I don't like how Details takes up
  screen space. It doesn't feel Mac-like."
- Row 23: "'Tags' should appear in a separate editing pane below the note, not in the Inspector or in Details."
- Row 32: "Folder locations should appear in the inspector, not in the main window — it takes up too much room."
- Row 7: the date and the tags can't be edited in the list, as the title can.

## Today

The note pane (`NotesBrowserView.DetailPane`) stacks, top to bottom: a two-line header (title; date,
quality, authors), the **Locations** block (one row per folder), a **Details** disclosure holding
`NoteMetadataInspector` (Round-up or Sources, Authors, Date and Sent with, Quality, **Tags**, Zotero), capped
at a share of the pane's height, and then the editor. Nothing in the menu bar opens or closes Details.

## Recommendation: an inspector panel on the right, tags in a bar under the note

```
┌ Notes ─────────────────────────────────────────────────────────────────────────────────────────┐
│ ◧  ✎  Notes|Extracts              🔍 Search                                    ⓘ (inspector)  │
├──────────┬──────────────────────────────┬───────────────────────────────┬─────────────────────┤
│ Folders  │ Title        Date    Tags    │ 📄 Letter to Hamilton         │ Round-up            │
│ ▸ 1790s  │ Letter to H… 1791-03 treas…  │ 1791-03 · ★★★ · J. Madison    │  2 linked PDFs: 1791│
│ ▸ Banks  │ Bank notes   1791    bank    ├───────────────────────────────┤  [Use 1791]         │
│          │ …                            │                               │ ─────────────────── │
│          │                              │  The editor: the whole        │ Authors             │
│          │                              │  height between the header    │  J. Madison         │
│          │                              │  and the tag bar.             │ ─────────────────── │
│          │                              │                               │ Date                │
│          │                              │                               │  [March 1791     ]  │
│          │                              │                               │  ☐ Uncertain        │
│          │                              │                               │ Sent with  [      ] │
│          │                              │                               │ ─────────────────── │
│          │                              │                               │ Quality  ★★★☆☆      │
│          │                              │                               │ ─────────────────── │
│          │                              ├───────────────────────────────┤ Locations           │
│          │                              │ Tags: (treasury ×) (bank ×)   │  📁 1790s        ⊖  │
│          │                              │       [add a tag…          ]  │  📁 Banks        ⊖  │
│          │                              │                               │ ─────────────────── │
│          │                              │                               │ Zotero              │
└──────────┴──────────────────────────────┴───────────────────────────────┴─────────────────────┘
```

1. **The inspector** (rows 20, 21, 32). A fourth panel at the window's right edge, as in Pages, Keynote,
   Xcode and Finder's preview pane. **View ▸ Show Inspector / Hide Inspector, ⌥⌘I** (the macOS convention;
   ⌘I is Italic in Notes, so the Reader's ⌘I is not available here), and a toolbar button
   (`sidebar.right`). Open or closed and its width are remembered, like the folder list's. It holds, in
   order: Round-up (a note) or Sources (an extract), Authors, Date with Sent with and the calendar, Quality,
   **Locations** (moved out of the main window), Zotero. It reads `nav.detailItemID` exactly as Details does
   now, so it follows the selection in the same pass as the editor. With nothing or several items selected
   it says so, as the header does. The panel uses the window's existing `PanelDivider`, like the folder list,
   so it resizes the same way (about 220–360 pt, default 260) and its width enters the window's minimum the
   same way. In the stacked layout it runs the full height beside both the list and the note.
2. **The tag bar** (row 23). Under the editor, always shown while a note is selected: the tags as tokens
   with a remove ×, and the entry field (the `W40.fix-notes-tag-entry` field with autocomplete and Return).
   One line when the tags fit; it wraps up to three lines, then scrolls inside itself, so the editor keeps
   its height. Tags leave the inspector.
3. **The note pane** keeps only the two-line header, the editor and the tag bar. The Locations block and the
   Details disclosure (`an.detail.metadataToggle`, `NotesLayoutSettingsKey.metadataCollapsed`) go; no
   migration of that setting is needed because there is nothing to migrate. The header stays because it is
   the visible selection signal and it shows the date and authors when the inspector is closed.
4. **The list** (row 7). The Date and Tags cells become editable in place, as the Title is: double-click or
   Return on the cell. Date uses the one typed-date parser of `W40.fix-notes-date-entry`; Tags uses the tag
   bar's field. The Reader's `InlineEditCells.DateCell` and `TagEntry` are the pattern.

### Why an inspector rather than a sheet like the Reader's Edit Info…

- A sheet is modal: it covers the note and stops typing until it is closed. In the Reader, Edit Info edits
  files the owner is triaging, often several at once, so a modal step fits. In Notes the fields are read and
  changed while writing the note beside them (the date while reading a source, Round-up's suggested year,
  a location), which an always-available, non-modal panel serves better.
- The inspector shows the fields at a glance without a click; a sheet shows them only while open.
- A sheet would also need a shortcut other than ⌘I.

What the inspector costs: about 260 pt of width while it is open. Closed, the note pane is larger than
today, since Locations and Details leave it.

### Other options

- **B. A sheet like the Reader's Edit Info…** Note ▸ Edit Info… (⌃⌘I or ⇧⌘I), the same sections as the
  inspector; the tag bar and list editing as above. Uses no width, but is modal.
- **C. Both.** The inspector, plus Edit Info… for several selected notes at once (setting a date or a tag on
  all of them). Notes has no multi-item field editing today, so C adds that work; it can be filed later.

## For the build session

- Build after `W40.fix-notes-date-entry` and `W40.fix-notes-tag-entry`: they replace the controls that move
  here (`NoteMetadataInspector.swift`, `NoteTagsInspector.swift`); the build moves containers, so landing it
  first makes them conflict.
- List editing (part 4) can be split into its own item if the build runs long; it does not depend on 1–3.
- Accessibility ids keep the `an.detail.*` names for the moved sections so the UITests follow them; add
  `an.inspector`, `an.inspector.toggle`, `an.tagbar`. VM checks: ⌥⌘I and the toolbar button toggle it;
  it follows the selection; locations remove from the inspector; the tag bar adds and removes; the stacked
  layout; the window's minimum width with the inspector and the folder list both open.
