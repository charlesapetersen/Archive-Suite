# Reader — Advanced Search (design for the owner)

From the owner's Reader guided session 1 (2026-11-04, row 33: "Find worked as expected — an Advanced Search as
well"). Design only; written by `W40.reader-advanced-search-design`. The build is `W40.reader-advanced-search`,
waiting on the owner's answer (`W40.reader-advanced-search-owner-ok`). Delete this page when the build ships.

## What exists today

- **Find** (toolbar field): one box, OCR full text through the content index (`ContentIndex`, SQLite FTS5,
  bm25 over name ×10 / classification ×5 / body ×1). Every word is quoted and AND-ed, so a phrase, OR and
  exclusion cannot be typed.
- **Filter bar** (`LibraryFilter`): subjects (all or any, no "not"), quality set, read state (all / unread /
  read / no read state), date from-year to-year (either date role), ambiguous dates, needs attention, a filename
  substring, one folder (`pathPrefix`).
- **Smart folders** (`SavedSearch` = a name + a `LibraryFilter` + the Find text). Opening one makes it the base
  scope; the filter bar layers on top (AND); Clear goes back to the base.

## What Advanced Search combines

One form, every section optional, sections AND-ed together:

| Section | Fields | New to the Reader? |
|---|---|---|
| Text (OCR, name, classification) | all of these words · this exact phrase · any of these words · none of these words · where: anywhere / OCR text only / file name only | phrase, any, none and *where* are new (FTS5 does all four natively) |
| Subjects | has all of · has any of · has none of | "none of" is new (the filter bar keeps its no-NOT rule) |
| Quality | the 1–5 checkboxes, plus "no quality tag" | "no quality tag" is new |
| Read state | All / Unread / Read / No read state | same as the filter bar |
| Document date | from … to … as a year or a full date; which date: either / Date / Date Uncertain; include undated: yes/no | full dates and the role choice are new |
| Folders | inside any of these folders (multi-pick) · not inside these folders | several folders and exclusion are new |
| Other | needs attention only · ambiguous dates only | same as the filter bar |

Results land in the normal list, sorted by relevance when there is text, with the usual snippets.

## Mock-up (recommended form: a sheet, ⌥⌘F or the ⋯ beside Find)

```
┌─ Advanced Search ──────────────────────────────────────────────────┐
│ TEXT          All of these words   [ budget  deficit            ] │
│               This exact phrase    [ "balanced budget"          ] │
│               Any of these words   [ Stockman  Darman           ] │
│               None of these words  [ draft                      ] │
│               Look in  (•) Anywhere  ( ) OCR text  ( ) File name   │
│ SUBJECTS      Has all of  [Treasury ×] [+]   Has any of  [+]       │
│               Has none of [Press ×] [+]                            │
│ QUALITY       [x]1 [x]2 [x]3 [ ]4 [ ]5   [ ] no quality tag        │
│ READ STATE    ( ) All  (•) Unread  ( ) Read  ( ) No read state      │
│ DATE          From [1981      ] to [1983-06-30]  on [Either date ▾] │
│               [ ] include undated documents                        │
│ FOLDERS       Inside   [Box 12 ×] [Box 14 ×] [+]                   │
│               Not in   [Duplicates ×] [+]                          │
│ OTHER         [ ] needs attention only  [ ] ambiguous dates only    │
│                                                                    │
│ 1,204 documents match                                              │
│ [Clear]            [Save as Smart Folder…]   [Cancel]   [Search]   │
└────────────────────────────────────────────────────────────────────┘
```

The match count updates as fields change (the filter is an in-memory pass over `LibraryIndex`; the text part is
one FTS query).

## How it relates to smart folders

- An Advanced Search **is** a smart folder's definition: "Save as Smart Folder…" stores it, and **Edit Smart
  Folder** opens the same sheet filled in. Today a smart folder can only be made from the filter bar's state, and
  edited only by re-saving.
- Running a search without saving behaves like opening an unsaved smart folder: it becomes the base scope, the
  filter bar layers on top, Clear returns to it, and choosing a folder or All Files leaves it.
- Data: `SavedSearch` grows the new fields (phrase, any, none, where, subjects-none, no-quality, full dates,
  date role, folder lists). No migration is written because there is nothing to migrate (owner, 2026-08-01).
- Find stays the quick box. Optionally, Find learns the same syntax (`"phrase"`, `OR`, `-word`) so a typed query
  and the form agree; that is cheap once the form's query builder exists.

## Build size

Medium (one item, two or three sessions): a query struct and FTS builder in `ContentIndex` with tests for each
operator; `LibraryFilter` additions with tests; the sheet; smart-folder edit; a UITest in the VM.

## The question for the owner

Which form? (1) The sheet above, fixed sections, smart folders edited through it — recommended. (2) Finder-style
rule rows (+/− rows, "all/any of the following rules"), more flexible and about twice the work. (3) No form: only
teach Find the syntax (`"phrase"`, `OR`, `-word`) and add "none of" to the filter bar. Also: is a subject
exclusion ("has none of") wanted, given the filter bar's settled no-NOT rule?
