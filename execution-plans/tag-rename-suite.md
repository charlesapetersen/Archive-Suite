# Rename or merge a tag across the suite, and the Tags window (`W40.tag-rename-suite`, design)

Owner, 2026-11-06: "This is important functionality. Also, tag changes in one app should carry over to the other
apps." Owner, 2026-11-14: one Tags window in each app, built once and shared (`W40.tag-window-core`, `-reader`,
`-notes`, `-processor`). This note designs both; this item builds the carrier, Notes' rename and merge, and the
Processor's vocabulary following. The window items build the window on top of it.

## What there is today (checked 2026-11-26)

- **Reader.** Tags ▸ Rename Tag… and Find Similar Tags… (`NavigationModel.renameTag`, `RenameTagSheet`,
  `SimilarTagsSheet`). Renaming into an existing tag merges into its spelling; a case-only rename re-spells every
  case. Each file goes through `TagWriter.renameToken` (a coordinated fresh read), the batch is one `AuditLedger`
  group and so one Undo. In catalogue mode the rename edits the `.archivesuite.json` companions instead.
- **Notes.** No rename or merge. Subjects live in each note's front matter (`Item.tags`), title-cased by
  `NotesTagVocabulary.normalizedSubjects`, mirrored onto the note's own `.md` by `NotesTagProjector`. No Undo for tag
  edits.
- **Processor.** No library. Two vocabularies: the autocomplete one (`ProcessorTagVocabulary.shared`, ArchiveCore
  `TagVocabulary`, one spelling per `tagKey`, only ever grows) and the controlled subject list (UserDefaults
  `tagVocabulary`, the Output tab's sheet) that LLM subject tags are held to.
- **Shared files.** The suite already keeps its own files in the archive's hidden `.archivesuite` folder
  (`SPEC/containers.md`, `SPEC/collection-settings.md`), written through `ContainerFileStore`: a temporary file
  renamed over the old one, every step through the folder's descriptor, `flock` from the check to the rename, a stamp
  check so a change in between is refused. Notes already writes one suite file into a granted archive folder (the
  root marker, `ReaderRootStore`).

## Decision: a change log in the archive, applied by each app on its own items after the user says so

Each app is sandboxed to its own store and writes it through its own audited writer, so no app writes another's
items. What crosses is a **record of the change**, `<archive root>/.archivesuite/tag-changes.json`, and each app
applies it to its own items with its own writer, on the user's say-so.

Why the archive root: it is the one folder every app can reach (the Reader's granted root; Notes' granted Reader
roots; the Processor is not sandboxed and its output folder is its archive root), it travels with the archive to a
second Mac, and the suite already keeps its files there. The alternatives were weighed and dropped:
- *An app group container* (one folder all three apps share). Self-signed builds have no Team ID, and macOS asks the
  user each launch before an app reads a group container it is not provisioned for. It would also not travel with
  the archive.
- *One app asking for access to the other's store.* Notes would write the Reader's files, or the Reader Notes'
  notes, while the owning app has them open: the safety model of the 2026-11-14 decision forbids it.

### The record

UTF-8 JSON, sorted keys, written and read through `ContainerFileStore` (same lock, stamp, link and size rules; a
newer `schemaVersion` is never interpreted nor overwritten; an unreadable file is left alone and reported).

```json
{ "schemaVersion": 1,
  "changes": [ { "id": "UUID", "at": "2026-11-26T19:00:00Z", "app": "reader",
                 "from": "Civil Rights", "to": "Civil Rights Movement", "withdrawn": false } ] }
```

- One entry per tag changed. A merge of three tags into one is three entries with the same `to`. A rename is an entry
  whose `to` no item carried before; the record does not tell them apart and needs not: applying either is the same
  operation, "every item carrying `from` carries `to` instead".
- `from` matches by the suite's tag identity (`tagKey`: case-folded, accents kept; `SPEC/tag-format.md` invariant 4).
  `to` is the spelling the changing app wrote. Each app then spells the result by its own rule: the Reader writes `to`
  as recorded (into an existing tag it takes that tag's library spelling, as its own rename does); Notes title-cases,
  as it does every subject.
- A case-only change (`from` and `to` the same tag) is a re-spelling. The Reader applies it; Notes title-cases every
  subject anyway, so for Notes it is a no-op and is marked handled without asking.
- Facet tokens the suite writes itself (ratings, Quality, dates, read state, flags, item type, colour names; the
  `keepsExactCase` set) are never renamed through the record: a writer refuses to record one, a reader skips one.
- The record holds the newest 2,000 entries; older ones are dropped when an entry is added. An app that has been
  closed for longer than that misses the oldest, which it reports.

### Each app's handled list

Each app keeps, in its own settings, the ids of the entries it has handled for each archive root (keyed by the root
marker's guid, so a moved archive keeps its list): applied, skipped, or its own. An entry is pending for an app when
it is from another app, not withdrawn, not handled, and some item of this app carries `from`. An entry no item
carries is marked handled without asking.

### When an app opens, or the other app is closed

Nothing happens to a closed app. The record waits in the archive. When an app next opens its library (the Reader its
root, Notes its library with a reachable Reader root, the Processor at launch) it reads the record and, when there
are pending entries, shows **Tag Changes from Other Apps**: one row per entry ("The Reader renamed “A” to “B” on
26 Nov · 12 notes carry “A”"), each with Apply and Skip, and Apply All. Apply runs that app's own rename on its own
items, as if the user had typed it there: one Undo, partial failures counted, nothing else touched. Skip marks it
handled. Closing the sheet leaves the rest pending for the next open; the Tags menu reopens it (Tags ▸ Tag Changes
from Other Apps…).

The Processor has no items, so its vocabularies follow without asking (§Processor).

### Undo across apps

Undo in the app that made the change reverts its own items, as today, and marks the entry `withdrawn`; Redo clears
the mark. An app that has not yet applied the entry no longer offers it. An app that already applied it is not
reverted behind the user's back: undoing a merge in one app cannot know which of the other app's items carried which
tag, and the other app's own Edit ▸ Undo still holds its step if the user wants it. Its sheet shows the withdrawn
entry once as a notice ("The Reader undid renaming “A” to “B”; your notes keep “B”. Use Rename Tag… to change them
back."), with no action, and marks it handled.

### A tag the other app spells differently

Matching is by `tagKey`, so `civil rights` in a note and `Civil Rights` on a file are one tag for the record. Each app
writes its own spelling rule (above). The Reader's existing library-spelling rule and Notes' title-casing are both
unchanged.

### A read-only or unreachable archive

The change is made in the app regardless; recording it is a second step. If the archive root is missing, not
granted, read-only, locked by another writer for longer than five seconds, or holds a record this build cannot read,
the app says so in its status line ("Renamed on 12 notes. The other apps were not told: the archive folder is
read-only.") and keeps nothing to retry: the user's next rename is unaffected. Reading needs no write, so a read-only
archive still delivers changes recorded on another Mac.

Notes with several Reader roots records the change in each root it can reach, and reads each.

### Writes

- **Reader:** after a rename batch finishes with at least one file changed, appends one entry whose id is the batch's
  ledger group (so `undoLast` and `redoLast` of that group mark it), and marks it handled. Catalogue mode the same.
- **Notes:** Rename Tag… and Merge write entries the same way after the notes are saved; the Notes Undo step marks them
  withdrawn. Notes writes nothing else in the archive: this file and the root marker are its only two writes there,
  each through one ArchiveCore seam (`TagChangeLog`, `RootMarker`).
- **Processor:** writes no entries (it has no rename until `W40.tag-window-processor`; that item records through the
  same seam).

## Notes' Rename Tag… and Merge (this item)

- **Tags ▸ Rename Tag…** (and the tag bar's right-click): the subject, a new name, "affects N notes and extracts".
  Renaming into an existing subject merges into it. **Tags ▸ Find Similar Tags…** groups near-duplicates with the
  Reader's `TagSimilarity` (moved to ArchiveCore) and merges a variant into the chosen spelling.
- `NotesModel.renameSubject(from:to:)` runs over every note and extract carrying the subject (matched as Notes'
  `removeTag` matches, after title-casing; and by `tagKey`, so a hand-edited lower-case spelling is caught), one
  atomic `withItem` per item with subject projection, as the bulk tag edit does. A note that fails is counted and
  named in the status line; the others stand.
- **One Undo:** the step holds each changed note's tags as they were and puts them back through the same per-item
  transaction (a delta that restores only the renamed subject, so an edit made since to another tag survives); Redo
  repeats the rename on the same notes.

## Processor's vocabularies follow

At launch and when the output folder changes, the Processor reads the record at its archive root and, for each
entry not yet handled (withdrawn ones included, see below), re-spells its vocabularies: the autocomplete vocabulary
drops `from` and holds `to` (a new `TagVocabulary.rename(from:to:)`), and the controlled subject list replaces a line
matching `from` by `to` (dropping a duplicate). A withdrawn entry it already applied is reversed the same way when
`from` is no longer on any item it knows of: the vocabulary is a list of spellings, not a record of items, so there
is nothing to lose. Its handled list is kept in its own settings.

## The Tags window (`W40.tag-window-core` and the per-app items; owner, 2026-11-14)

One SwiftUI window, written once in a small UI package beside ArchiveCore (ArchiveCore stays UI-free) and fed by
each app with its items and its writer:

- **Model (ArchiveCore):** `TagInventory`, built from `(itemID, [subject])` pairs: each tag by `tagKey`, its spellings
  with counts, its item count, and the similar clusters (`TagSimilarity`). Facet tokens are listed apart and are not
  editable here. Change plans (rename, merge, remove) are pure values the app's writer executes, so they are tested
  on in-memory items.
- **Window:** a searchable, sortable list of subjects with counts; Rename (into an existing tag merges), Merge of
  several selected into one spelling, Remove from every item (a confirmation that names the count), Find Similar as a
  filter, and a click that shows the items carrying the tag. Each change is one Undo, and each rename or merge is
  recorded in the change log above (Remove too, as an entry with an empty `to`, once the window ships it; schema 1
  readers skip an entry they cannot apply).
- **Tag Changes from Other Apps** becomes a section of the window.
- **Reader:** fed by its library, writes through TagWriter; `RenameTagSheet` and `SimilarTagsSheet` retire into it.
- **Notes:** fed by its notes and extracts, writes through `renameSubject` and the bulk remove.
- **Processor:** lists both of its vocabularies (the autocomplete spellings and the controlled list), each marked;
  rename, merge and remove edit them and record the change. It does not walk the output folder: those files are the
  Reader's library, so the Reader applies the change to them.

## Tier-2 and tests

A write to every tagged file and note, and a new write class in the archive. Adversarial review; scratch-copy tests:
- ArchiveCore: the record's load, append, trim, withdraw, a newer schema refused, a link refused, a concurrent
  writer (`changedSinceRead` retried), a read-only folder reported.
- Notes: rename, merge, case variants, a note failing mid-batch, Undo and Redo restoring exactly, the record written
  and withdrawn, a pending entry applied and skipped.
- Reader: the entry written after a rename and withdrawn by Undo; a pending entry applied through `renameTag`.
- Processor: both vocabularies re-spelled from a record, a handled entry not reapplied.
- VM UITests: Notes' Rename Tag… sheet and the Tag Changes sheet.
