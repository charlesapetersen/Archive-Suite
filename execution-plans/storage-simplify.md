# Where each fact is stored, and one home for each (W49.storage-simplify-audit, 2026-11-20)

Owner, 2026-11-20 (call 26): "The number of places we're saving dates seems like an artifact of development. We
should review this and similar things and simplify." This is the read-only survey: every place the suite writes a
fact about an item, who reads each copy, which copy wins, which copies exist only because of how the apps were
built, and a proposal for one home per fact. Nothing was built or run. Four read-only code surveys (dates; item
fields, sender and kind; containers, checks and staging; storage roots), with the surprising findings checked by
hand. File and line references are to origin/main of 2026-11-20.

The owner's question is at the end (§9). The build items it calls for wait on his answer
(`W49.storage-one-home-owner-ok`).

## 1. The stores today

| Store | Lives | Who writes | Seen outside the suite |
|---|---|---|---|
| **Finder tags** (extended attribute) | on the file | Processor at output, Reader edits, Notes (Quality), Finder by hand | Finder, Spotlight, DEVONthink; kept by Finder copies (an attribute, so some cloud and network copies drop it) |
| **Page 2** (the text page; for the searchable form the same header in XMP `archivesuite:pageHeaders`) | in the PDF | Processor only; it rewrites its own new output in place for the evidence line and a reclassification | Spotlight and DEVONthink full-text, Preview, any copy of the PDF |
| **PDF Info / XMP Dublin Core** | in the PDF | only `Creator: Archive Processor`, PDF/A ids and processing-time `CreateDate` | carries no item fact |
| **JSON sidecar** `<name>.json` (or `JSON Output/`) | beside the PDF | Processor; patched after cover-letter dating | anything reading JSON; not with a copied PDF; not moved by a Finder rename |
| **`.archivesuite/`** in each folder: `item-fields.json` (with `dates`), `containers.json`, `container-levels.json`, `container-names.json`, `collection-settings.json`, `runs/`, `corrections/` | beside the files, hidden | Reader (item fields, dates records, containers), Processor (collection settings, runs, container backfill), Live Capture at Finish (containers) | nothing; only the Zotero export carries containers out |
| **Reader caches** `content-index-v2.sqlite3`, `library-index-v1.sqlite3`, thumbnails | Reader's container | Reader | none; rebuildable |
| **Reader user data in caches**: flags (`flaggedPaths` setting), page turns (library index DB) | Reader's container | Reader | none; keyed by absolute path, so lost on a move |
| **Live Capture staging**: relay objects, `manifest.json`, `staging-manifest.json` | relay folder, incoming folder | phones, Processor | none; transient, turned into tags and files at Finish, then trashed |
| **Notes** front matter and index | the `.archivenotes` library | Notes | its own notes only; it copies no corpus PDF fact |

## 2. Fact by fact

**Dates** (Year or Decade, Month, Day, Date Uncertain, Sent With, the chronological sort key). Up to six copies:
1. **Finder tags.** Authoritative everywhere: every reader parses them with `DocumentTags.parse`, the Zotero export
   takes `issued` from them only, and a Reader correction writes only them (`UserItemFields.set` refuses dates:
   "dates are tags").
2. **Page-2 `Document date:` / `Sent with:` lines.** Written by Live Capture only (Process Files never writes them,
   SPEC line ~422). **No app reads them**; Improve OCR and the evidence rewrite only carry them forward. They go
   stale on the first correction. *An artefact.*
3. **Sidecar `date`, `date_uncertain`, `sent_with`, `sent_with_uncertain`, `enclosure_of`.** **No production
   reader** (checked: the only `["date"]` reads are Notes' own front matter and the Zotero connector's CSL).
   *An artefact.*
4. **Page-2 `Date evidence:` line** (why the date was chosen). Read by the Reader's Checks and folder dating; it
   counts only while its `gave <date>` matches the tags. *User-facing provenance that travels with the PDF.*
5. **Sidecar `dating` object** (the full evidence). **No reader.** It is the fallback when the PDF could not be
   rewritten. *An artefact.*
6. **`.archivesuite/item-fields.json` `dates` records.** Written by the Reader when the user accepts a folder-date
   offer; it beats the page-2 evidence line while its date still matches the tags. It holds no date that the tags
   lack: **it exists only to stand in for the page-2 line the Reader may not rewrite.** *An artefact of the
   never-rewrite rule.*

The sort key is not stored (worked out from the tags), except in Notes' own index for its own notes. Folder dates in
`containers.json` are a container's date, not an item copy (below). Ruled out: file names, file dates (no app sets
them), XMP/Info document dates.

**Item fields** (document kind, title, byline, publication, publication date, recipient place). Three homes:
page 2 (the read value), the sidecar `item_fields` (the same values with quotes and `not_filled`), and
`item-fields.json` (the user's corrections, keyed by file name). The Reader's index and Checks read user value
then page 2; only the Zotero export also reads the sidecar, to fill a field page 2 lacks. A Finder rename orphans a
correction, and a later file given the old name inherits it (W49.reader-item-fields-rename). The Processor never
reads the corrections, so a re-run's new page 2 hides under old corrections, or loses them if names change
(W49.proc-item-fields-rerun). `item-fields.json` exists **only because the Reader never rewrites PDFs**.

**Sender, recipient, sending place.** Sidecar only (the entity call's `entities`, else the tagging call's names),
corrected in `item-fields.json`. **Never on page 2**, so no outside tool and no copied PDF sees a sender. That is
a gap, not a duplicate.

**Kind and classification** are four different facts:
- the segmentation **Classification** (Document Start, Continuation, Box, Folder): page 2 only, cached in the
  Reader's index. Internal to the pipeline; fine as is. (The SPEC said its raw values appear in sidecars; only
  `box_label`/`folder_label` do, as `format`. Corrected in this commit.)
- the **reading kind** (`Kind:` handwritten, typed…): page 2 only. Fine.
- the **document kind** (letter, memo, clipping): an item field (above).
- **item type, Quality, colour**: Finder tags only, echoed transiently in relay objects and session manifests.
  Fine.
"Classified"/"Secret" markings are not a stored field anywhere; they are body text.

**Container and collection values** (collection, series, box, folder, repository; collection settings). One home:
`.archivesuite/containers.json` (precedence user > label > path, most specific first) and
`collection-settings.json` plus write-once `runs/`. Path values are never stored. The Live Capture manifest holds
card values until Finish moves them into `containers.json` (crash safety), and the Processor keeps a label-read
cache. **Already one home per fact.** They are folder facts, not item facts, so the folder is the right place. They
reach outside tools only through the Zotero export.

**Checks.** `Checked <Field>` Finder tags, set only by a person in the Reader; a `user` container value and a user
item-field value also count as checked. One home each. Fine.

**Reader user data kept in caches.** Flags (the `flaggedPaths` setting) and page turns (the library index) are
keyed by **absolute path**: a moved file, or a moved or renamed root, loses them (`FlagStore.swift` says so in a
comment; no KNOWN_ISSUES bullet until this commit). These are user facts in a cache.

## 3. What each copy is for

| Copy | Verdict |
|---|---|
| Finder tags for dates, Quality, type, colour, subjects, checks, read state | **Keep.** The home: Finder, Spotlight and DEVONthink see them. |
| Page 2: OCR text, provenance, classification, reading kind, evidence, item fields | **Keep.** Travels with the PDF; full-text tools see it. |
| XMP `pageHeaders` | **Keep.** It *is* page 2 for the searchable form, not a second copy. |
| Page-2 `Document date:` / `Sent with:` | **Drop.** No reader; Live Capture only; stale after any correction. |
| Sidecar date keys and `dating` | **Drop.** No reader. |
| Sidecar `item_fields`, `entities` and names | **Drop as a store** once page 2 carries the names (§4). Keep the sidecar only as an opt-in export. |
| `item-fields.json` (fields and `dates`) | **Exists only for the never-rewrite rule**; goes or stays with the option chosen (§4). |
| `containers.json`, `collection-settings.json`, `runs/` | **Keep.** The one home for folder facts. |
| Reader caches | **Keep**, re-keyed by root marker GUID and relative path (§6). |
| Flags, page turns | **Move** out of path-keyed caches (§4, §6). |
| Live Capture staging | **Keep.** Transient. |

## 4. One home per fact: the options

All three options drop the unread copies (page-2 date lines, sidecar date keys and `dating`) and keep tags and
the folder store as they are. They differ on the facts a user corrects: item fields, sender and recipient, date
evidence, page turns.

**A. The file carries its facts (recommended).** Tags for what you sort and filter by; page 2 for what was read
from the page, including **new Sender, Recipient and Sending place lines**. **The Reader rewrites page 2** when the
user corrects a field or accepts a folder date, through one audited ArchiveCore writer (the Processor's own
in-place page-2 rewrite, moved to the package). Page turns become the page's real rotation in the PDF. Flags become
a Finder tag. `item-fields.json` and the sidecar stop being stores.
- *Outside tools:* Spotlight, DEVONthink, Preview and a copied PDF see the corrected values; Finder sees flags.
- *Renames:* nothing to orphan; W49.reader-item-fields-rename goes away.
- *Re-runs:* the `Checked <Field>` tags already mark which values the user set; a Processor re-run keeps those
  values when it remakes page 2 instead of reading them again. W49.proc-item-fields-rerun becomes that rule.
- *Owner call 24* ("only corrected on page 2 if the user does Improve OCR"): answered; the correction is on page 2
  at once.
- *Cost:* the Reader's first write to PDF bytes (§5), Tier-2. A PDF with no suite page 2 (anything the Processor
  never made, including the pre-app corpus) has nowhere to put a correction. Either the Reader offers corrections
  only on files with a page 2 (taking typing away on other PDFs: a withholding, so his call), or those files alone
  keep a folder-store entry. Sub-question in §9.

**B. The folder carries corrections.** The Reader still never writes a PDF. Page 2 keeps what was read, marked as
read; one per-folder store (`.archivesuite/items.json`, replacing `item-fields.json`) holds every per-item user
fact (fields, names, evidence of a folder date, page turns, flags), keyed by file name plus file identity so a
Finder rename follows (W49.reader-item-fields-rename option a). Sender lines still go on page 2 as read.
- *Outside tools* see only the read value; a correction lives in a hidden file no other tool reads, and a copied
  PDF leaves it behind.
- *Re-runs:* the store wins over any new page 2, as today.
- *Cost:* small; mostly a merge of today's files, no SPEC change to the never-rewrite rule.

**C. Today's split, tidied.** Drop only the unread copies; keep `item-fields.json` and the sidecar names as they
are; the rename and re-run items go ahead as asked.

Why A: it is the only option where each fact has exactly one copy and every outside tool sees the user's value.
B keeps two copies of every corrected field (page 2's stale read and the store), which is the same kind of
duplication the owner asked to remove, now made explicit.

## 5. The Reader's never-rewrite rule (owner, call 25)

Today: SPEC invariant 1 ("Reader MUST NOT … re-save, or alter any file's bytes"), the Reader's Core Directive, its
write-surface lint, and the Reader KNOWN_ISSUES accepted on it. What a Reader PDF write would need, under A:
- **One writer in ArchiveCore**, from the Processor's in-place page-2 rewrite (`dateEvidenceRewrite`,
  `classificationRewrite`), so both apps produce the same bytes. It edits only the suite's text page (or the XMP
  header of a searchable page) and a page's rotation; it never touches the image pages' content.
- **Write beside, verify, replace**: write a new file next to the old, re-read and check it (PDF/A-2b, the
  text-page structure, image data-fork hash of untouched pages, page count), then swap with a coordinated
  `.forReplacing` write. Re-apply and verify the Finder tags and colour (a swap does not keep them by itself).
- **Undo**: the previous bytes go to a per-folder `.archivesuite/previous/` (or the Trash) until the undo window
  closes; Undo swaps them back.
- **A file open elsewhere**: coordinated access; refuse and say so when the file is busy or not downloaded.
- **The lint** keeps every other write path closed; the new writer is its one named exception, as
  `RootMarker.ensure` is today.
- Where it helps beyond item fields: date evidence after a folder date, page rotation, and sender and recipient.
Under B or C the rule stays as written.

## 6. The suite-wide storage path and several Reader roots (call 27)

**Unified storage path** (ArchiveNotes/POTENTIAL_FEATURES.md, "Unified suite-wide storage path + migration"). Under
A and B every fact lives with the files (tags, page 2, the folder's `.archivesuite/`) or in the Notes library. What
is left outside them is caches and settings. So moving to a new computer is: copy the archive folder and the Notes
library, then re-grant each once; the root marker keeps the identity and Notes' links keep working. Two things stand
in the way today, both Reader data keyed by absolute path:
- flags and page turns (user data; lost on a move) — moved out by A or B;
- the content index, page thumbnails and the library index (caches; re-extracted after a move) — re-keyed by root
  marker GUID plus relative path, so a moved root keeps its warm index.
**Simpler** under either option. A shared default location for the three apps (Processor output, Reader root,
Notes library) then needs no migration at all; it stays a wish until the owner asks for it.

**Several Reader roots.** Notes already resolves links against several GUID-keyed roots (`ReaderRootStore`); the
wishlist line saying "a single granted Reader root" was out of date and is corrected in this commit. The Reader app
itself shows one root. Nothing in the proposed homes is per-root, so several roots become a Reader interface
question (walk and merge N roots; the library index is already keyed per root). **Simpler**; it stays a wish.

## 7. SPEC changes and migration

**SPEC changes, by option.**
- All options: `tag-format.md` §2-page PDF drops the `Document date:` / `Sent with:` lines; the sidecar section
  (today a few passing mentions) says it is an export with no date keys and no reader.
- A: invariant 1 gains the named page-2 and rotation writer; §Field checks says a correction is written on page 2
  and the `Checked <Field>` tag marks it; new Sender / Recipient / Sending place header lines; `containers.md`
  drops the `item-fields.json` `dates` records (evidence lives on page 2); a `Flagged` facet.
- B: `item-fields.json` becomes `items.json` with file identity; page 2 marks item fields as read values.

**Migration.** None for app output: no app has produced material the owner keeps (owner, 2026-08-01), so the dropped
copies are simply no longer written, and the test `.archivesuite/item-fields.json` files on scratch copies are
discarded. The owner's pre-app corpus keeps its Finder tags, already the date home, so nothing in it moves. Under A,
its PDFs have no suite page 2; whether they get one belongs to the corpus migration (§8), not to this change.

## 8. With W49.corpus-specific-audit

That survey (open) asks what the apps carry only for the owner's corpus. Overlaps found here:
- the Processor dates from a folder's date only for pre-OCRed files (`OCRProcessor+Tagging.swift:1117-1123`);
- the legacy `P8`–`P10` Quality alias on read;
- the Box and Folder colour marks.
None of the proposed homes depends on them. That survey should take these homes as given: a one-time corpus
migration writes the same tags and, under A, a page 2, exactly as the apps do.

## 9. The question for the owner (Daemon Report, needs you)

Which option: **A** (the file carries its facts; the Reader may rewrite page 2 and page rotation through one
audited writer; recommended), **B** (the folder store carries corrections; the Reader never writes a PDF) or **C**
(today's split, with the unread copies dropped)? Under A, for a PDF with no suite page 2: (i) no corrections until it
is processed, or (ii) a folder-store entry for those files only?

Filed, each waiting on his answer (`W49.storage-one-home-owner-ok`):
- `W49.storage-drop-dead-copies` [S]: stop writing the page-2 date lines and the sidecar's date keys and `dating`.
- `W49.storage-one-home` [L]: build the chosen option (A: the ArchiveCore page-2 writer, Reader corrections onto
  page 2, the sender lines, re-run keeps checked values, the SPEC; B: the merged per-folder store with file
  identity). It replaces W49.reader-item-fields-rename and W49.proc-item-fields-rerun under A.
- `W49.reader-root-movable` [M]: flags and page turns out of absolute-path keys (a tag and the PDF under A, the
  store under B); the Reader caches keyed by root marker GUID and relative path.
W49.item-fields-home's question is this one; it waits on the same answer and closes with it.
