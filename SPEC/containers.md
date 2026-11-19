# Archive Suite — where an item sits in its archive (`SPEC/containers.md`)

## Purpose & status

Repository, collection, accession, series, box and folder for every item, worked out from the label photos (Route
A) or a labelled folder tree (Route B), and corrected by the user in one place, the Reader. The design, the measured
corpus figures and the owner's approval (2026-11-13, `W47.ct-design-ok`) are in
`execution-plans/containers/00-plan.md`; the readers per field are measured in
`ArchiveProcessor/segbench-results/ct-read.md`. This document is the contract every app keeps. The model is
`packages/ArchiveCore/Sources/ArchiveCore/Containers/` (`W47.ct-spec`); the inference that fills it from markers,
folder names and the level map is `ContainerInference` and `ContainerPatterns` there (`W47.ct-infer`). When this file and the code disagree, fix one of them in the same
commit.

There is no production material yet (owner, 2026-08-01), so the shape may change outright. `schemaVersion` exists so
that an older build leaves a newer document alone. It is not there to carry a migration.

**File safety.** Writing the container file and the level map is a new write class in the corpus: **new files only**,
inside the hidden `.archivesuite` folder; no file outside it is rewritten, renamed, retagged or moved, and nothing is
deleted. Tier-2, tested on scratch copies (Reader Core Directive). Both files are found by their path, never by a
Spotlight query (Wave 26). `CorpusWalker` skips hidden folders, so neither is ever indexed or shown as a document.

## The fields

Every field is optional; most collections have only some. A value is the text as written on the label or in the
folder name; how it is shown (title case, the user's standard names) is §Showing a value. The
key is the JSON name; the segbench name is `ct_truth.py` `FIELDS_REV`.

| key | segbench | example | home level | CSL |
|---|---|---|---|---|
| `repository` | repository | Hoover Institution Archives | collection | `archive` |
| `place` | place | Stanford, CA | collection | `archive-place` |
| `collectionTitle` | collection_title | Albert Glotzer papers | collection | `archive_collection` |
| `collectionSubtitle` | collection_subtitle | Correspondence and writings | collection | `archive_collection`, after a colon |
| `collectionNumber` | collection_number | Mss 1036, SC0122, RG 165 | collection | `call-number` |
| `accession` | accession | 91006-10.V | collection | `note`: `accession: …` |
| `series` | series | Series II | collection | `note`: `series: …` |
| `seriesTitle` | series_title | Manuscripts | collection | `note`, after the series |
| `container` | container | Box 17, Carton 9, Folio 3 | box | `archive_location` |
| `boxTitle` | box_title | Subject file | box | `archive_location`, in brackets after the container |
| `folder` | folder | 8 | folder | `archive_location` |
| `folderTitle` | folder_title | Reports 1959-1960 | folder | `archive_location`, after the folder |
| `date` | date | 1946-2001 | the run's own | not exported |
| `other` | other | a barcode, "Restricted" | the run's own | not exported |

- `series` and `accession` hold a value only when the label or name says "Series", or "Accession" / "ACCN";
  an unlabelled number goes in `other` (owner's sheet notes, 2026-11-05).
- `container` is the type and its own number: "Box 34" for "Box 34 of 201". `folder` is the folder's number
  alone; a folder marked "5-9" is container "Box 5", folder "9".
- `date` and `other` describe the container they were read from, not its items; they are kept for the user and the
  folder-date rule (`W47.ct-folder-date`, unsettled) and are not exported to Zotero.

## A value and its source

Each field holds `{ "value": V, "source": S }`, and may add `reader` and `confidence`:

| key | meaning |
|---|---|
| `value` | A string. `""` set by the user means "none here": it hides a value from any other source. An empty value from any other source is no value. |
| `source` | `path` (the folder tree, Route B), `label` (a label read, Route A) or `user`. |
| `reader` | For `label`: the route that read it, e.g. `vision+parser`, `gpt-5.6-luna`, `gemma-3-12b`. Kept when the user confirms. |
| `confidence` | Optional, 0 to 1: the reader's own, or the measured rate for that field and route. A display hint, never a rule. |
| `at` | When the value was set (ISO 8601). |

**Precedence: user, then label, then path.** A re-read never overwrites a `user` value. A label value is a proposal
until the user confirms it; confirming makes it `user` and keeps `reader`. The readers per field (owner,
2026-11-13): box and folder numbers from Vision + parser; repository, collection title, collection number and date
from GPT 5.6 Luna on the gateway, else Gemma 3 12B, proposed and confirmed once per run; accession from Luna, else
Vision + parser; collection subtitle, box title, folder title and other marks from the user. The Processor asks Gemma
only on a server on the same Mac that lists it (`W47.ct-capture-gemma`); with none, it proposes the parser's values
for those fields.

`path` values are worked out from the tree and the level map each time they are read and are **never stored**, so
renaming a folder renames its value. A stored `path` value from another writer is read as `path`.

## Runs and the inheritance rule

A **run** is a record per container, not per item. It has a `level` (`collection`, `box` or `folder`), a `start`
(the file name it begins at) and its `fields`. A box or folder label photo starts a run of its level at itself, the
item type telling which (`SPEC/tag-format.md` §Item type; a "No Folder" sheet is recognised by its text and starts a
folder run with no fields). The user may start a run anywhere ("set for selection" splits runs).

- **Order.** Files are taken in Finder's order within one directory: `localizedStandardCompare`, ties broken by
  plain string comparison (`ContainerOrder`). Hidden files and folders take no part.
- **Cover.** A run covers the files from its `start` up to, not including, the next run of its own level or a
  shallower one (a new box ends the folder run; a new collection ends both). Its `start` need not exist: a run
  begins where its name would sort, so removing the label photo does not move the run.
- **Live runs.** At any file at most one run of each level is live, shallow to deep: the collection run, the box
  run inside it, the folder run inside that. Runs cover only files directly in their directory, never a
  subfolder's.
- **Masking.** Taking the live runs shallow to deep, a run of level L hides every value an earlier live run gave a
  field whose home level is L or deeper. A new box therefore clears the folder fields and the container, even
  where its own label read gave no number. `date` and `other` take the level of the run that holds them.
- **Where a value is kept.** A value lasts as long as the run that holds it. So a label read stores each value in
  the run of its field's home level: a box label's collection title and series go into the collection run live at
  that box, and carry across boxes; its container and box title go into the box run. Only a box label starts or
  changes a collection run. With none live it starts one at itself. A read agreeing with the live run
  (`ContainerNames.key`) fills in the fields that run lacks, so a later box's accession reaches the earlier boxes of
  the same collection. A read naming another title or collection number starts a new collection run with the read
  alone; one differing only in another field (a new series or accession) starts one holding the live run's values
  with the read over them, so the title and repository carry on. Where a differing value is the user's, nothing
  changes and a warning says so. A folder label's box number is not stored: it is not a check on the box run (owner, 2026-11-13), and a folder
  run holding a container would outrank the box label's read.
- **Directories.** The container file's `directory` block applies to every file in the directory and below. Path
  values (from the level map) apply the same way.
- **Choosing a value.** For each field the candidates are, most specific first: the unmasked values of the live
  runs, deepest run first; then the path values in the file's own name (§Name patterns); then the file's own
  directory's `directory` block, then its path values; then the parent's, and so on up to the archive root. The candidate with the highest source wins, and among the same source
  the most specific. A disagreement between candidates (the tree says Box 12, the label Box 13) is a warning shown
  by `W47.ct-infer`, never resolved silently. A box number lower than the one before is not a warning (27% of
  steps between box photos go down), nor is a folder label naming another box (Vision misreads it about one time in
  five) (owner, 2026-11-13).

One correction to a run fixes every item under it.

## The container file

`<directory>/.archivesuite/containers.json`, in the directory that holds the files it describes; it moves with the
folder. UTF-8 JSON, sorted keys, dates ISO 8601 in whole seconds (read with or without fractions), at most 1 MB.

| key | meaning |
|---|---|
| `schemaVersion` | `1`. A reader that finds a larger number must not interpret the document, and a writer must not overwrite it. |
| `directory` | `{ "fields": { key: value, … } }`: values for this directory and everything below it. |
| `runs` | The runs, each `{ "start": name, "level": L, "fields": { … } }`, in order of `start`, then shallow to deep. At most one run per `start` and `level`; a reader keeps the first. |
| `updatedAt` | When the document was last written. |

Reading is lenient: an unknown field key, an unknown source or level, or a malformed value drops that value or run,
not the document, so the rest can be shown. A document without an integer `schemaVersion` is unreadable. A directory,
`.archivesuite` or document that is a link, not of the expected kind, too big or not JSON is left alone and reported.

**Versioning.** A build that adds a field, a source, a level or any key bumps `schemaVersion`. Reading notes every
value it drops (an unknown key that is not null, a malformed value, a duplicate run); a writer never overwrites such
a document (`ContainerFileStamp.droppedOnReading`), so an older build cannot erase a newer one's values even within
one version. The run order in a file does not matter; readers sort.

**Setting aside.** A document that is unreadable or holds values this build drops is shown as far as it reads, and
is replaced only on the user's explicit say-so (`write(…, settingAside: true)`): it is renamed, never deleted, to
`containers.json.set-aside-<yyyyMMdd-HHmmss UTC>-<id>` in `.archivesuite`, and the new document written in its place.
A newer document is never set aside.

Writing (`ContainerFileStore.write`):
- opens the directory and `.archivesuite` without following a link at either, creating `.archivesuite` if it is
  missing (and only it: a missing directory is an error), and does every later step through that folder's
  descriptor, so a link swapped in cannot send the write elsewhere. Callers pass resolved paths: a directory that is
  itself a link is refused, for reading too;
- holds an exclusive `flock` on `.archivesuite` from the check to the rename, so two apps editing at once never
  overwrite each other unnoticed;
- refuses a document it cannot read, of a newer `schemaVersion`, holding values it dropped, or changed since the
  writer read it (inode, size and modification time, `ContainerFileStamp`); a first document is put in place only if
  none appeared meanwhile (`RENAME_EXCL`). On a volume without `flock` or exclusive rename (exFAT, some network
  shares) the same checks run without them;
- writes a temporary file `.<name>.<uuid>.tmp` in `.archivesuite` and renames it over the old one, so a reader sees
  the old document or the new, never half. A temporary file left by a crash is ignored by readers.

## The level map (Route B)

`<root>/.archivesuite/container-levels.json`, in the folder a user chose as the root of a tree (a Reader archive
root, a folder dropped on Process Files). It applies to the tree under that folder; the nearest map above a
directory wins. Written only when the user confirms the pre-filled map, once per root; same writing rules as the
container file. Reading is strict: a role this build does not know makes the map unreadable, so it is left alone.

| key | meaning |
|---|---|
| `schemaVersion` | `1`. |
| `levels` | The role of each depth below the root, first entry for its direct subfolders: `repository`, `collection`, `accession`, `series`, `box`, `folder` or `ignore`. A depth past the list names nothing. |
| `overrides` | Relative path (names joined by `/`, as written) to `{ "role": R, "children": C? }`, for one directory. |
| `updatedAt` | When the map was confirmed. |

The Reader (`W47.ct-reader-view`) takes as the root of the tree the archive's main folder: the folder the user
granted, or its "Archival Photos" folder when it holds one. It offers the pre-filled map once per root, after the
root's scan has settled, and from File ▸ Container Levels…, and writes it only on Save, only into the tree the sheet
was made for. The nearest map above a directory wins even when this build cannot read it: that subtree then has no
path values, rather than an outer map's.

- In `levels`, `ignore` occupies its depth and names no field ("ignore this level").
- An override with role `ignore` is a workflow folder ("05 Final Tagging"): it names no field and does not count, so
  its subfolders take the role it would have had. Any other override role names that directory's role, and its
  subfolders continue with the role after it in `levels`.
- A role that appears twice in `levels` (two series depths) is taken at the first depth at or after the current one.
- `children`, when set, is the role of the subfolders' depth (one of `levels`): `{ "role": "ignore", "children":
  "collection" }` on "05 Final Tagging/5 Priority 5" makes the folders under it collections.

Role to field: `repository` → `repository`; `collection` → `collectionTitle` (a collection number in the name, such as
`SC0122` or `Mss 1036`, goes to `collectionNumber`); `accession` → `accession`; `series` → `series`; `box` →
`container`; `folder` → `folder`, the rest of the name `folderTitle`. How a name splits is §Name patterns.

**Pre-filling** (`ContainerLevelMap.prefilled`, `ct_read.py` `level_map`). Each depth takes the role that at least
half its names suggest on their own, weighed once per file under them and counted by `ct_read.py`'s classes (a box
and folder name apart from a box name, a tie to the greater class name); a depth whose names suggest none takes the
role its neighbours imply: `ignore` below a box, folder or collection, `repository` above a collection, `collection`
above a box, folder, series or accession or below a repository. A workflow folder (two digits and a space: "05 Final
Tagging") becomes an `ignore` override, so it does not count as a depth. The user confirms or edits the map before
it is written. On the Route B tree set (`ct_trees.json`, 36 trees) the map is right for every tree and every field
matches (`ContainerInferenceTests`).

## Name patterns (Route B)

`ContainerPatterns`, the patterns `ct_read.py` scored (`segbench-results/ct-read.md` §Route B); a change here is
scored there too. Names read underscores as spaces; numbers lose leading zeros ("Folder 08" is folder `8`) and a
letter suffix is capitalised. Every value is a `path` value.

| role | name | values |
|---|---|---|
| any box or folder | `B17F8`, `Box 10 - Folder 3`, `Bx 3 Fd 12`, `Box 2, Folder 4 - Reports` | container `Box 17`, folder, folder title after a dash or comma |
| box | `Box 17`, `Carton 9`, `Folio 3`, `B82`, `box_017`, `Box 1-3`, `Box 3 - Subject file` | container as type and number or range, box title after a spaced dash, comma or colon |
| folder | `Folder 8`, `F15`, `f. 5`, `ff. 1-20`, `Folder 08 - Correspondence` | folder number or range, folder title after it |
| box, folder | a name with no number ("Oversize", "Correspondence 1950") | box or folder title |
| series | `Series II, Manuscripts`, `Subseries 3`, `Entry 77` | series (`Series II`, Roman numerals in capitals), series title after it; otherwise the name |
| accession | `Accession 91006`, `Accn 91006`, `2005 Accession` | the number or year; otherwise the name |
| collection | `SC0122`, `Kristol papers, Mss 1036`, `SC0122 News Service`, `MC 1968 - Title`, `HUG(FP) 15.2` | collection number (`Mss`, `SC`, `RG`, `RU`, `R-MC`, `CBI`, `MC`, `M`, `HUG(FP)` and digits; before the title only unspaced or set off by a dash, comma or colon); the rest the title |
| repository | the name | repository |

A name suggests a role on its own (for pre-filling) by the same patterns, then "papers", "records", "collection",
"files", "diaries" or "manuscripts" for a collection and "archives", "library", "institution", "institute",
"society", "museum", "university", "college", "center" or "foundation" for a repository; a box name with a title
after it is not taken for a box ("Box 3 - Smith Papers" suggests a collection, as in `ct_read.py`). A file name carrying
both numbers (`Fromm, Box 2, Folder 4 - 0004.pdf`) gives the file a container and folder (`fields(ofFileName:)`).

## Route A: markers into runs

`ContainerInference.applyMarkers` turns one directory's box and folder photos, each with its item type (the `Box` /
`Folder` tag, a root's colour setting for older material, or the page-2 Classification) and its label read, into
runs in the directory's container file, by §Runs and the inheritance rule. A folder photo stores its folder, folder
title, date and other marks, never a box number or collection field; a "No Folder" sheet (its text says "no
folder") starts a folder run with no fields. A run already at that start keeps every user value; a re-read replaces
the label values it reads and removes nothing, and applying the same reads twice changes nothing. A read never
hides a user value: a photo inside a run the user set, of its own level or deeper, starts no run (it would end the
user's run there), with a warning; except a photo the user marked as a start, the companion's Box or Folder button
(`ContainerMarker.startedByUser`), since starting a run there is the user's own act, so long as its run would cover
only files filed with it, none that was already in the directory (`recordMarkers`' `filedNow`). A value one box's read filled into an earlier run stays there if a re-read
changes it; the user corrects the run. The caller shows the result for the user to accept before anything is
written.

**Reading a label** (`ContainerLabelReader`, W47.ct-processor-capture). `parse` is `ct_read.py` `vision_read`, the
Vision + parser route as scored, from the photo's text lines and its item type. The Processor runs Apple Vision
(accurate) on the photo for those lines; where Vision reads nothing it parses the run's OCR text, reader
`ocr-text+parser`, a route not scored. `proposals` takes container, folder,
series and series title from it; repository, collection title, collection number, date and accession from a model's
reading of the photo when there is one, else from the parser; the container from the model only where the parser
reads none; and collection subtitle, box title, folder title and other marks from nobody, for the user to write. A
folder label keeps only folder, folder title, date and other marks. Every value is source `label` with its `reader`
until the user confirms it. In Live Capture the marker's card shows them (through §Showing a value) for correction
and Save confirms them; at Finish each filed marker's run starts at its own PDF in the collection folder. Process
Files writes them as proposals, for the Reader.

## Warnings

`ContainerInference.applyMarkers` and `.warnings` give the warnings; they are shown, never acted on.

- **Disagreement**: a file's candidates for a field name different values (`ContainerDisplay.disagreements`, so
  wordings under one standard name agree). Consecutive files with the same fields in disagreement are one warning. A
  field whose value is the user's is settled and not a disagreement: correcting or confirming a value in the Reader
  ends its warning (W47.ct-reader-edit).
- **A read against the user**: a label read names a different value from the user's on the run it falls in or
  starts; the user's value stands.
- **A photo inside the user's run**: a box or folder photo inside a run the user set, of its level or deeper; no run
  is started there.
- **A marker with no read**: a box or folder photo whose read gave nothing it stores ("No Folder" sheets excepted).
- **A long unmarked run**: in a directory with runs, more than 60 files in a row with no run starting among them
  (the owner's corpus: median 10 documents between markers, 90th percentile 56).
- Not warnings (owner, 2026-11-13): a box number lower than the one before, and a folder label naming another box.

## Showing a value (`W47.ct-normalise`)

Values stay as written; only what is shown changes (`ContainerDisplay`, `Containers/ContainerNames.swift`). The
comparisons in `ct_read.py` fold case, so they are untouched.

- **Title case.** A value written wholly in capitals is shown in title case by the suite's one rule
  (`Text/TitleCase.swift`, shared with the Reader's Copy Cleaned for Prose): "BOX 12" and "JANE DOE PAPERS" show as
  "Box 12" and "Jane Doe Papers"; acronyms, initials, Roman numerals and words with no vowel ("UCLA", "MSS", "II")
  stay. Mixed case is the writer's and is left.
- **Standard names.** The user may give one standard name to the wordings of a repository, a collection or any other
  field: "Special Collections, Example Library, Example University" and "Example University Library Special
  Collections" both show as "Example University, Example Library". Wordings match with case, accents, width and
  punctuation folded and `&` read as "and" (`ContainerNames.key`). A standard name is per field and shown as the
  user wrote it. An entry may also say which parts of a label go into which field: it gives text for other fields,
  which fill a field only where the record has no value of its own (a user's "none here" counts as one; the newest
  entry fills first), or it gives
  no text for its own field, which then shows nothing.
- A wording belongs to one entry per field; setting a new entry takes its wordings from older ones and comes first,
  so it wins.
- Two candidates under one standard name, or differing only in case, punctuation or spacing, are not a disagreement
  (`ContainerDisplay.disagreements`).

The names live in `<root>/.archivesuite/container-names.json`, beside the level map, for the tree under that root; the
nearest file above a directory wins. Same writing rules as the container file. Reading is strict, as the level map's:
a field or key this build does not know makes the document unreadable, so it is left alone.

| key | meaning |
|---|---|
| `schemaVersion` | `1`. |
| `names` | Newest first, each `{ "field": F, "variants": [wording, …], "fields": { F2: text, … } }`; the first that matches wins. |
| `updatedAt` | When the names were last changed. |

## Zotero (CSL-JSON)

`ContainerCSL` maps a resolved record to CSL-JSON variables; `W47.ct-zotero` adds the item's own fields and writes
the export. No citation is formatted.

- `archive` = repository; `archive-place` = place; `call-number` = collection number.
- `archive_collection` = collection title, then `: ` and the subtitle when there is one.
- `archive_location` = the container, the box title in brackets, then `Folder <n>` (the number as written if it
  already says "Folder" or "f."), then the folder title, joined by `, `: "Box 17 (Subject file), Folder 8, Reports
  1959-1960".
- `note` (Zotero imports it into Extra), one line each: `accession: <accession>`, `series: <series>, <series title>`.
- An empty field is left out; nothing is invented.
