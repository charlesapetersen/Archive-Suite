# Improve OCR — the Reader ↔ Processor contract

Normative for both apps (W44.reocr-processor implemented the Processor side, W44.reocr-reader the Reader's). The
`OCR Poor` flag and the text-page header are in [`tag-format.md`](tag-format.md) §Poor OCR and §2-page PDF structure.
Why it is built this way: §6 (the design plan it came from, `execution-plans/reocr/00-plan.md`, is in git history). The
types named here are ArchiveCore's (`packages/ArchiveCore/Sources/ArchiveCore/Links/`); a change to this contract
changes them, both apps and this file together, under Tier-2.

## 1. The shared support folder

Each app connects it once through its own folder panel (suggested: `~/Library/Application Support/ArchiveSuite/
ImproveOCR`, `ImproveOCRSupportIdentity.suggestedLocation`; the sandboxed Reader opens its panel at the person's real
Library, since its own `suggestedLocation` would name its container) and keeps its own bookmark (the Reader a
security-scoped one). It must be on a local volume, not cloud-synced, and not inside an archive root
(`ImproveOCRFlagStore.checkSuitable`); it grants nothing over an archive. Layout:

| path | written by | what |
|---|---|---|
| `store.json` | the first app to connect | `{storeID, created}`: the folder's identity (`ImproveOCRSupportIdentity`). Each app saves the ID on connecting and refuses a folder whose ID differs ("reconnect"). |
| `Requests/<uuid>.json` | Reader | a hand-off manifest (§2), 0600 in a 0700 folder, regular owned non-link file, ≤ 1 MiB; the lowercase UUID, named by `ImproveOCRManifest.url(for:in:)` and published by `ImproveOCRManifest.stage(in:)`. |
| `Receipts/<operation UUID>.json` | Processor | a content-revision receipt (§4). |
| `Flags/<sha256>/` | both | one file's flag generations (§3). |

Every file is published whole: written to a synced temporary in the same folder and linked into place
(`link(2)`), so no reader ever sees part of one. No JSON is read, changed and written back.

## 2. The hand-off

`archiveprocessor://improve-ocr?request=<UUID>&root=<root GUID>&rel=<path>&rel=<path>…` (at most 8 files and 8 KiB),
or `archiveprocessor://improve-ocr?request=<UUID>` with the manifest staged at `Requests/<UUID>.json` first
(`ImproveOCRRequest`, `ImproveOCRManifest`: root GUID, root path hint, and per file its relative path, optional 0-based
pairs, inode, size and SHA-256; at most 1,000 entries; 24 hours). Paths are relative, never absolute, empty or with
`..`. A link only opens the Processor's review dialog: it never reads a page, spends, clears a flag or writes a file.
The Processor checks the request, finds the archive (the hint, else its own saved grant, else its own panel, each
checked against the root marker's GUID), resolves each path inside that root after links, requires a regular file
matching the manifest's inode, size and digest, and only then records the request ID (`Consumed/` in its own
state), so a replayed link opens nothing twice and a refused or cancelled one stays usable.

## 3. Flag generations

`ImproveOCRFlagStore`: `Flags/<sha256(lowercase root GUID, NUL, NFC relative path)>/` holds `lock`, `key.json`
(informational), `intent.json` and `events/NNNNNNNNNN.json`. The key comes from `FileKey(rootGUID:root:file:)`, which
resolves both paths and spells each component as the volume stores it, so both apps name one file one way. **A file's
archive is the nearest folder above it that holds a root marker** (the Reader searches no higher than its granted
root; both stop at a marker they cannot read, and refuse rather than look past it). So a granted folder holding an
older marked subfolder keys that subfolder's files under the subfolder's GUID in both apps, and a hand-off names
one archive (a selection across two is refused). Every
suite action that changes `OCR Poor` (the Reader's flag, unflag, a generic subject edit or undo that touches it; the
Processor's clear on acceptance and re-flag on restore):

1. takes the file's `flock` lock (`withLock`, ≤ 10 s, never inside or around an NSFileCoordinator block: the lock
   first, then the coordinated tag write). Off the main thread, with one stated exception: the Reader's generic
   tag edits (a subject edit, rename, undo or redo that names the tag) run on the main thread as every Reader tag
   write does, and wait at most 1 s there; its Flag/Unflag command runs off it;
2. `begin`s with the wanted value: a new generation and the operation ID, synced, before the tag moves; refused
   while another action's intent is unfinished;
3. changes the tag through the app's audited tag writer;
4. `commit`s with the value actually read back.

A crash between 2 and 4 leaves the intent as a barrier until `reconcile` records the tag as it is (an unreadable
intent included). Every writer holds the lock from `begin` to `commit`, so an intent found under the lock belongs to
an action that died: either app reconciles it with the tag as read (when the tag cannot be read, the Reader refuses its
action and the Processor records it flagged), and the Processor then treats its review as out of date. Once the tag
write has happened, a record that cannot be committed never makes the write look refused: the write is recorded in
the app's ledger (the Reader's line marks the record unfinished), the record reconciled if it can be, and the Reader's
Flag command says so.
Every action advances the generation, even when the tag already had the value. An acceptance clears only the generation it reviewed (`begin(ifGenerationIs:)`); a flag set again during the read, in the suite or
outside it, stays. Finder or another tool can remove and re-add the tag with no event: a boolean tag cannot show that,
so callers re-read the actual tag inside coordination.

## 4. Receipts

`ImproveOCRReceipt`: operation ID, root GUID, relative path, the improved text-page indices (the page's own index
when its searchable layer is edited), the SHA-256 before and after, `published` or `restored`, and a date. Written once per operation after the new bytes are in place and
verified, independently of the flag; a retried or rebuilt receipt for the same revision is the same receipt. It
carries no OCR text and grants no access. The Reader (`ImproveOCRReceiptInbox`, on each library change, on activation
and every 20 s while connected) finds the file among its own library's rows, inside its granted root, by the receipt's
archive GUID and relative path (normalized, then by full key), drops the file's index entry regardless of its modification time, lets its ordinary incremental pass re-extract
the bytes as they are now (a later change wins over a stale receipt; it never loads a saved version), reloads a
document window showing the file on the same pair, and then records the receipt as seen in its own defaults (every ID,
uncapped). It never writes or removes a receipt; one it cannot place (another archive, a file not listed yet, a
format it cannot read) stays unseen and is looked at again when the library changes.

## 5. What the Processor guarantees about the file

Improve OCR accepts readable, unsigned, unencrypted PDFs. The candidate keeps a byte-for-byte original prefix
when the file uses a cross-reference table. Files ending in a cross-reference stream use a full save with the pinned
PDFium because its incremental revision after a stream does not open in Quartz. Both save modes check kept page object
graphs and rendering, and verify the new text. Publication keeps the path, the Finder tags as a multiset, label, other
extended attributes, resource fork, ACL, mode, flags, and creation, modification and date-added times. The inode and
change time change. A verified copy of the replaced file stays available in Processor history until the person removes it.

For positively identified suite pairs, the candidate replaces the separate text page and updates any invisible OCR
layer on its scan. For a standalone or unpaired page, it writes searchable text directly on the existing page. Pages
in an ambiguous arrangement stay in place and receive direct layer edits. Any suite header and provenance stored in
XMP stay with the file. The new reading follows the detected lines when placement holds the whole reading. Otherwise,
when the page needs an invisible layer, the new reading remains searchable and selectable with lines spread down the
page. The candidate must keep the scan's boxes, rotation, annotations, and original image streams and pass a render
comparison. A layer that cannot be edited safely or a candidate that fails verification disables acceptance. The receipt
lists the physical page indices of the separate text pages or directly edited pages. The Reader re-extracts the whole file.

**The image each page is read from (W49.proc-reocr-preservation, owner call 34, 2026-11-22).** When the file's
catalogue companion maps an image page to a [Preservation Copy](catalogue.md#preservation-copies), the reader gets
that exact intake original, or the mapped page of a multi-page PDF original, instead of the reading PDF's image. The
Processor opens it with `PreservationCopy.open`, checked against the identity embedded in the snapshot it reads, so
the bytes are the ones the map's digest names; it never downloads an offline copy and never writes in the
Preservation folder. The original is turned to match the reading page, which the reader reads with rotation off: an
upright JPEG keeps its compressed image data, anything else goes as an upright JPEG decoded at most 12,000 px on
its long side; neither carries the original's location (GPS) metadata. The whole original is sent, since the Processor
files one reading page per intake image. The
turn comes from searching small grey renditions of the original at each quarter turn for the reading page; no clear
winner is a fallback. The same reader runs either way, with its size target and the collection's sharing switches.
A page with no recorded copy, or one that is missing, offline, unverified, unreadable or unmatched, is read from the
reading PDF's image as before, and the review names, for every page, the Preservation Copy it read or why it read the
reading PDF (`ReOCRImageInput`).

**The catalogue record (W49.proc-item-fields-rerun, owner calls 24 and 32).** New text is a new content generation of
the same file. When the snapshot's identity matches a verified [catalogue](catalogue.md) companion, the candidate's XMP
identity names a new `contentRevision` of the same `fileID`, and the job's record keeps the step. After publication,
and before the receipt, `CatalogueWriter.advanceContentRevision` moves the companion to that generation under its
folder lock, once the PDF there proves it with the companion's page count. Only `contentRevision`, `revision` and
`parents` change: every correction, clear, check and evidence entry, made before the run or since, is carried. Improve
OCR reads text only, so it adds no field observation; the replaced text page's header lines are history. Restore puts
back the old bytes, which carry the old generation, and moves the companion back the same way, keeping a correction
made after acceptance. A move that fails is retried by launch recovery, which reports it, and History keeps the
operation until the move is settled; a refused move is reported. A file whose pair cannot be verified (companion
missing, offline, unreadable, newer or naming another generation), or a candidate that cannot carry the new identity,
is improved as before: the PDF keeps its identity, the companion is untouched, and the review says why
(`ReOCRCatalogue`).

## 6. Why it is built this way (design record)

Folded from the design plan when the Reader side shipped (W44.reocr-plan, 2026-11-07; the plan is in git history).

- **The dialog lives in the Processor.** It holds the keys, the model catalogue, the ranking, prices and the OCR
  engine. The Reader marks a person's dissatisfaction and hands the selection over; it never reads a page for OCR,
  spends, or writes file contents. The Reader's `TagWriter` stays metadata-only: content writes live only behind the
  Processor's `ReOCRFileWriter`, and ArchiveCore shares values and parsers, never a corpus content writer.
- **A private candidate first, published only on acceptance**, at the original path, so no app ever sees a
  provisional replacement. Rejecting it leaves the original untouched. The PDFium save is checked as described
  in §5. Incremental revisions retain the previous text in the file's history. A verified copy of the replaced file
  stays available until the person removes it, and Restore is its own guarded transaction.
- **Pages, ranking, cost.** Improve OCR reads the scan slots of validated pairs and reads each unpaired page directly.
  Each page shows its stored provenance where available and its stored or provisional Kind. Correcting a Kind re-ranks through the same solver the settings use. Missing evidence is
  "not measured", never zero; a run needs the person's explicit action after the estimate.
- **Flag generations** (§3) exist so an acceptance can tell whether the flag it reviewed is still the flag on the file:
  a flag set again during a re-read must survive the acceptance. They cover cooperating suite actions only; a boolean
  tag cannot show a Finder remove-and-re-add.
- **Receipts** (§4) exist because publication keeps the file's dates, which the Reader's index uses to skip unchanged
  files. Without a receipt, a replacement that keeps the dates is not noticed (Reader `KNOWN_ISSUES.md`, W44).
- **Local evidence, not benchmark truth.** A person's flag is a difficulty signal and an acceptance a preference; none
  is uploaded or added to benchmark truth automatically.
