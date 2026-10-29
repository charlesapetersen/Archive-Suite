# Archival containers — W47 (owner, 2026-10-21)

Repository, collection, accession, series, box and folder for every item, worked out from the label photos and the
folder names, and corrected by the user in one place. The owner asked for the assessment on 2026-10-21 and approved
filing it as drafted the same day, adding: *"Make sure to include 'Accession' as a field as well as 'Series.' Not all
collections of course will have these but they are common."*

This reverses the 2026-07-15 ruling that removed "Nested collection hierarchy (Box > Folder > Document)" as out of
scope (`ArchiveProcessor/POTENTIAL_FEATURES.md`). It was never on the declined list.

The owner added, the same day: *"we should not assume everyone will have their corpus structured like mine and we
should offer two common routes for others: photographing boxes and folders, and labeled file system structure."* So
the owner's corpus is one test case, not the design target; see "Two routes" below.

Citation management stays with Zotero. The Suite records where an item sits in an archive and hands those fields to
Zotero; it formats no citations.

## What exists (read 2026-10-21)

- The phone companions have Box and Folder buttons. A marker reaches the Mac as a group type, becomes a Red (box) or
  Purple (folder) PDF with a `Classification:` line on page 2 (`SPEC/tag-format.md`, colour labels and page-2
  header).
- The Processor OCRs the box photo and uses its first line, or an LLM's reading of it, only to name the output
  collection folder (`Capture/LiveCaptureProcessor.swift` `candidateName`; `Tagging/CollectionSegmenter.swift`). That
  prompt is told to drop box numbers, accession numbers and call numbers. Folder-label text is never used.
- No tag, PDF field, JSON sidecar key, Reader index column or Notes front-matter key holds repository, collection
  number, accession, series, box or folder.
- The Reader's Provenance column (`W18.reader-breadcrumb`) shows each file's own classification. It does not work
  out which box a document is in, and nothing is editable.
- Process Files reads a dropped folder flat (`Views/OCRView.swift`); a Box/Folder directory tree is lost.
- Notes source blocks show the filename and page. Notes reads Zotero but sends it nothing.
- `W46.seg-context` will test whether collection facts help the segmentation and tagging prompts. It would take its
  facts from the record this plan builds.

## The corpus (measured 2026-10-21, read-only, all 100,308 PDFs unless stated)

- Corpus PDFs are one page with an ABBYY or Acrobat text layer (394 of a sample of 400), not the Processor's
  two-page format.
- Level 1 of `Archival Photos/` names the repository for about 87% of PDFs. The rest sit under workflow folders
  ("05 Final Tagging", "03 Unconverted…") or topical ones ("Complete Journals", "General Clippings"). Under the
  workflow folders level 2 is a priority folder ("5 Priority 5") or "Re-OCR" and level 3 the collection: no
  repository level at all (W47.ct-truth, 2026-10-29; this line first said the repository sat a level lower).
- Level 2 names the collection informally ("Hoover Institute/Zschau"). A formal number (SC0122, M0333, RU 732,
  R-MC 118) is in the path for 12.8%, almost all Stanford. Lower levels hold accessions ("Initial Accession",
  "2005 Accession") and ad hoc groups.
- Box or folder appears in a path or filename for about 100 PDFs. Filenames are a sequence number and a short
  collection name, so capture order survives.
- Markers are colour tags only: 1,245 Red, 3,253 Purple, 7 both; no `Box`/`Folder` subject tags. The FinderInfo label
  byte disagrees with the tag array, so the tag array is the source.
- 202 of 327 directories hold markers, and 184 of those open with one. Carrying each marker forward in filename
  order reaches at most about 75% of documents; whether every box change was photographed is not measured. Untagged
  runs between markers: median 10 documents, 90th percentile 56.
- Box labels seen (10 of 17 viewed) are mostly printed and sharp, e.g. "STATE HISTORICAL SOCIETY OF WISCONSIN /
  Irving Kristol Papers, 1946-2001 / Mss 1036 / Box 10"; "HOOVER INSTITUTION ARCHIVES / ALBERT GLOTZER / BOX NO. 17 /
  ACCESSION NO. 91006-…"; "Edward Shils. Papers / Series II, Manuscripts / Box 101"; "Stanford University News
  Service / Series 1 / SC 122 Box 82" with a barcode. Accession and series both appear on printed labels.
- The existing text layer is not enough: on 300 sampled markers, 16 of 88 Red and 120 of 212 Purple have under 20
  characters, and only 52% of Red and 11% of Purple text holds a box, folder, series, accession or collection-number
  token. Of the box labels viewed, about half were read fully right; the misses drop the box or accession digits.
- Folder tabs are often handwritten, rotated or faint. Purple also marks "No Folder" dividers and some new-document
  pages, so it does not always mean a folder label.
- Survey data (scratch, not kept): the xattr inventory and per-directory marker sequences were in the 2026-10-21
  session scratchpad.

## Outside practice (desk research, 2026-10-21)

- Library guides tell researchers to photograph the box label and folder label before the contents (CUNY,
  McMaster); Cornell suggests Box/Folder directory trees. No shipped tool reads those label photos to assign what
  follows.
- Tropy has fixed Collection, Box and Folder fields (Archive is `dc:source`), no Series or Accession field, and its
  CSL export sends box and folder only if the user remaps them.
- Zotero's Manuscript, Letter and Document types have Archive, Loc. in Archive and Call Number (CSL `archive`,
  `archive_location`, `call-number`). CSL also defines `archive_collection` and `archive-place`, which Zotero takes
  in Extra. Chicago cites item, box, folder, collection number, collection, repository, place; it does not cite
  series.
- CSL-JSON import is the clean route into Zotero. Zotero's local API writes only from Zotero 10.
- ArchivesSpace defines a top container (type, indicator, barcode) once and links many items to it; series belongs
  to the intellectual hierarchy, not the physical one. Automatic finding-aid lookup is patchy: Stanford's and Duke's
  ArcLight blocked a test request, Penn's answered.

## The fields

Every field is optional; most collections have only some.

| Field | Example | Zotero / CSL |
|---|---|---|
| Repository | Hoover Institution Archives | `archive` |
| Place | Stanford, CA | `archive-place` (Extra) |
| Collection title | Albert Glotzer papers | `archive_collection` (Extra) |
| Collection number | Mss 1036, SC0122, RG 165 | `call-number` |
| Accession | 91006, 2005 Accession | Extra (`accession:`) |
| Series | Series II, Manuscripts (subseries as free text) | Extra (`series:`) |
| Container | Box 17, Carton 9, Folio 3 (type and number) | `archive_location` |
| Folder | Folder 8 (number) | `archive_location` |
| Folder title | Reports 1959-1960 | `archive_location` |

`archive_location` is composed as "Box 17, Folder 8" with the folder title after it when present.

## Two routes, for any user

Researchers record the hierarchy in one of two common ways, and often mix them. Both are first-class, both feed the
same record, and neither assumes the owner's layout.

**Route A — label photos.** The user photographs the box label and folder label before the contents (the habit the
library guides teach). With the companions this is the Box and Folder buttons; for photos taken any other way, a
marker is a Red or Purple label, a `Box`/`Folder` tag, or a page the label classifier calls a box or folder label.
The label is read into fields and carried forward in capture order to the next marker of its level.

**Route B — a labelled folder tree.** The user sorts photos into directories named for the hierarchy, e.g.
`Hoover/Glotzer papers/Box 17/Folder 8/`, `SC0122/B82/F15/`, or `Kristol, Mss 1036/Box 10 - Folder 3/`. The app reads
the tree, offers a level map for the root ("level 1 = Repository, level 2 = Collection, level 3 = Box, level 4 =
Folder", or "ignore this level"), pre-filled from patterns it recognises in the names (`Box 17`, `B17F8`, `Carton 9`,
`Folder 8`, `f. 5`, `Series II`, `Accession 91006`, `Mss 1036`, `SC0122`, `RG 165`), and the user confirms or edits it
once per root. A level the user marks as a workflow folder ("05 Final Tagging") is skipped. Box and folder numbers
written into filenames (`Fromm, Box 2, Folder 4 - 0004.pdf`) are read by the same patterns.

**Mixed.** A tree gives repository and collection and photos give box and folder (the owner's own corpus), or the
reverse. Per field, the deeper or more specific source wins unless the user set it; a disagreement between the tree
and a label (folder says Box 12, label says Box 13) is shown as a warning, not resolved silently.

Neither route needs the companions, the Processor's capture flow or any particular naming scheme; Process Files
and the Reader both accept a plain folder of photos or PDFs from any source.

## Design

1. **A record per container, not per item.** A container run starts at a marker photo or a directory and covers the
   files after it in filename order until the next run of its level. An item inherits every field from the runs
   that cover it: the folder run inside the box run inside the collection. A new box run clears the folder fields.
   One correction to a run fixes every item under it.
2. **Each field records its source**: folder path (Route B), label read (Route A), or user. Precedence is user, then label, then path.
   A re-read never overwrites a user value.
3. **Storage: one small JSON file per collection directory**, keyed by the run's first filename, beside the files.
   It moves with the folder, all three apps read it, and no existing file is rewritten. Writing it is a new write
   class in the corpus: new files only, Tier-2, tested on scratch copies. `W47.ct-spec` fixes the name and format;
   it must not be Spotlight-indexed content (Wave 26).
4. **The Reader is the one place to edit**, because it sees the whole corpus: a Container column, facets for
   repository, collection, accession, series and container, an inspector that edits a run, "set for selection"
   (which splits runs), and warnings where a box number goes backwards, a marker has no read, or a run is long with
   no marker.
5. **The Processor fills the same record for new material**: it reads the label at capture and shows the parsed
   fields on the capture card for correction in the reading room; it writes the file at finalize; Process Files
   reads nested Box/Folder directories into runs.
6. **Notes and the Reader export to Zotero.** Notes shows the container in source blocks. "Copy for Zotero" (Notes)
   and "Export to Zotero" (a Reader selection) write CSL-JSON with every field gathered for the item, not only the
   container (owner, 2026-10-21: *"other metadata that may have been gathered such as date, author, recipient, type
   (letter, newspaper article), place, publication name, etc."*): title, date with its uncertainty, author,
   recipient, type mapped to a Zotero item type, author and recipient places, publication name as container-title,
   subjects as tags. These come from what the Processor already extracts (the page-2 header, the JSON sidecar, the
   date tags). A field the Zotero type cannot hold goes in Extra; an empty field stays empty.

Not in this plan: typed box and folder numbers on the phone (the label read should cover them), finding-aid lookup
(a later extra once the manual path works), and any citation formatting.

## The items (filed in `SUITE_TODO.md` §"Archival containers — W47")

The measurement comes first and the build waits on the owner's look at it (`W47.ct-design-ok`).

1. `W47.ct-truth` — the label truth set and the owner's disagreement sheet, plus a Route B test set of folder
   trees in common naming conventions.
2. `W47.ct-truth-owner-ok` — OWNER GATE: that sheet answered.
3. `W47.ct-read` — the free reading routes scored per field, the Route B name patterns scored on the tree set,
   plus carry-forward and Purple's meaning.
4. `W47.ct-read-paid` — the gateway arm.
5. `W47.ct-design-ok` — OWNER GATE: the figures and this design, before app code.
6. `W47.ct-spec` — `SPEC/containers.md` and the ArchiveCore model.
7. `W47.ct-infer` — the inference in ArchiveCore: both routes, the level map, the name patterns, merging.
8. `W47.ct-reader-view` — the column and facets.
9. `W47.ct-reader-edit` — the editor.
10. `W47.ct-processor-capture` — label reading at capture and the confirm card (waits on `W46.review-done`).
11. `W47.ct-processor-intake` — Route B in Process Files: nested directories read with the level map.
12. `W47.ct-backfill` — read the corpus's marker photos and propose runs for review.
13. `W47.item-fields-truth` — title, byline, publication name and date, document type and recipient place: a truth
    set extending W46's entity set with clippings and reports, and how well the current tagging fills them.
14. `W47.item-fields-build` — a title for every document and the fields that proved reliable.
15. `W47.ct-zotero` — source blocks, and the Zotero export with all gathered metadata.

## Item fields

The Zotero export carries the item's own fields as well as its container. Date, author, recipient and sending place
are already measured by the W46 review (`W46.fix-date-truth-score` and the dating items; `W46.fix-ent-truth`,
`W46.ent-score`, `W46.ent-robust`, letters, memos and telegrams only). Not measured anywhere on 2026-10-21: title (no
title field exists; the Processor extracts none), headline, byline, publication name and date for clippings, the
document's type as a Zotero item type (`W46.kind-atrium` measures page kind for choosing a reader, which is a
different thing), and recipient place. `W47.item-fields-truth` measures those on an extension of W46's entity set,
and `W47.item-fields-build` fills only the fields that clear the bar (owner, 2026-10-21).

Cost: `W47.ct-read-paid` under $0.50; a full read of the corpus's 4,500 markers about $2–4 on the gateway, priced
from `W47.ct-read`'s figures before it runs. The $3 rule applies to each item.
