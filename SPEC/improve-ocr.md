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

`ImproveOCRReceipt`: operation ID, root GUID, relative path, the replaced text-page indices, the SHA-256 before and
after, `published` or `restored`, and a date. Written once per operation after the new bytes are in place and
verified, independently of the flag; a retried or rebuilt receipt for the same revision is the same receipt. It
carries no OCR text and grants no access. The Reader (`ImproveOCRReceiptInbox`, on each library change, on activation
and every 20 s while connected) finds the file among its own library's rows, inside its granted root, by the receipt's
archive GUID and relative path (normalized, then by full key), drops the file's index entry regardless of its modification time, lets its ordinary incremental pass re-extract
the bytes as they are now (a later change wins over a stale receipt; it never loads a saved version), reloads a
document window showing the file on the same pair, and then records the receipt as seen in its own defaults (every ID,
uncapped). It never writes or removes a receipt; one it cannot place (another archive, a file not listed yet, a
format it cannot read) stays unseen and is looked at again when the library changes.

## 5. What the Processor guarantees about the file

The candidate is the original byte for byte followed by one incremental revision (pinned static PDFium) whose kept
pages' active object graphs are unchanged (`ReOCRPreservationCheck`); publication keeps the path, the Finder tags as a
multiset, label, other extended attributes, resource fork, ACL, mode, flags, and creation, modification and
date-added times (the inode and change time do change), and keeps a verified copy of the replaced file until the
person removes it in the Processor's history. Encrypted, signed, cross-reference-stream, raw one-page and
non-suite-structured files are refused for in-place improvement.

## 6. Why it is built this way (design record)

Folded from the design plan when the Reader side shipped (W44.reocr-plan, 2026-11-07; the plan is in git history).

- **The dialog lives in the Processor.** It holds the keys, the model catalogue, the ranking, prices and the OCR
  engine. The Reader marks a person's dissatisfaction and hands the selection over; it never reads a page for OCR,
  spends, or writes file contents. The Reader's `TagWriter` stays metadata-only: content writes live only behind the
  Processor's `ReOCRFileWriter`, and ArchiveCore shares values and parsers, never a corpus content writer.
- **A private candidate first, published only on acceptance**, at the original path, so no app ever sees a
  provisional replacement; rejecting it leaves the original untouched. Incremental PDFium revision (not a PDFKit
  whole-file save), proven by the original-as-prefix and active-object-graph check of §5; recoverable editing, not
  redaction (the old text stays in the file's history). A verified copy of the replaced file is kept until the person
  removes it, and Restore is its own guarded transaction.
- **Pages, ranking, cost.** Only positively validated image/text pairs are improved, and only their image slots are
  read; raw, odd, encrypted or signed files go to the separate-output route. Each page shows its current reader and
  stored or provisional Kind; correcting a Kind re-ranks through the same solver the settings use. Missing evidence is
  "not measured", never zero; a run needs the person's explicit action after the estimate.
- **Flag generations** (§3) exist so an acceptance can tell whether the flag it reviewed is still the flag on the file:
  a flag set again during a re-read must survive the acceptance. They cover cooperating suite actions only; a boolean
  tag cannot show a Finder remove-and-re-add.
- **Receipts** (§4) exist because publication keeps the file's dates, which the Reader's index uses to skip unchanged
  files. Without a receipt, a replacement that keeps the dates is not noticed (Reader `KNOWN_ISSUES.md`, W44).
- **Local evidence, not benchmark truth.** A person's flag is a difficulty signal and an acceptance a preference; none
  is uploaded or added to benchmark truth automatically.
