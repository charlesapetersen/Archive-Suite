# Improve OCR — the Reader ↔ Processor contract

Normative for both apps (W44.reocr-processor implemented the Processor side; W44.reocr-reader implements the
Reader's). The `OCR Poor` flag and the text-page header are in [`tag-format.md`](tag-format.md) §Poor OCR and §2-page
PDF structure. Design and rationale: `execution-plans/reocr/00-plan.md` (kept until W44.reocr-reader ships). The
types named here are ArchiveCore's (`packages/ArchiveCore/Sources/ArchiveCore/Links/`); a change to this contract
changes them, both apps and this file together, under Tier-2.

## 1. The shared support folder

Each app connects it once through its own folder panel (suggested: `~/Library/Application Support/ArchiveSuite/
ImproveOCR`, `ImproveOCRSupportIdentity.suggestedLocation`) and keeps its own bookmark (the sandboxed Reader a
security-scoped one). It must be on a local volume, not cloud-synced, and not inside an archive root
(`ImproveOCRFlagStore.checkSuitable`); it grants nothing over an archive. Layout:

| path | written by | what |
|---|---|---|
| `store.json` | the first app to connect | `{storeID, created}`: the folder's identity (`ImproveOCRSupportIdentity`). Each app saves the ID on connecting and refuses a folder whose ID differs ("reconnect"). |
| `Requests/<UUID>.json` | Reader | a hand-off manifest (§2), 0600 in a 0700 folder, regular owned non-link file, ≤ 1 MiB. |
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
resolves both paths and spells each component as the volume stores it, so both apps name one file one way. Every
suite action that changes `OCR Poor` (the Reader's flag, unflag, a generic subject edit or undo that touches it; the
Processor's clear on acceptance and re-flag on restore):

1. takes the file's `flock` lock (`withLock`, ≤ 10 s, never on the main thread, never inside or around an
   NSFileCoordinator block: the lock first, then the coordinated tag write);
2. `begin`s with the wanted value: a new generation and the operation ID, synced, before the tag moves; refused
   while another action's intent is unfinished;
3. changes the tag through the app's audited tag writer;
4. `commit`s with the value actually read back.

A crash between 2 and 4 leaves the intent as a barrier until `reconcile` records the tag as it is (an unreadable
intent included). Every action advances the generation, even when the tag already had the value. An acceptance
clears only the generation it reviewed (`begin(ifGenerationIs:)`); a flag set again during the read, in the suite or
outside it, stays. Finder or another tool can remove and re-add the tag with no event: a boolean tag cannot show that,
so callers re-read the actual tag inside coordination.

## 4. Receipts

`ImproveOCRReceipt`: operation ID, root GUID, relative path, the replaced text-page indices, the SHA-256 before and
after, `published` or `restored`, and a date. Written once per operation after the new bytes are in place and
verified, independently of the flag; a retried or rebuilt receipt for the same revision is the same receipt. It
carries no OCR text and grants no access. The Reader validates it against its own granted root and the file's current
bytes, invalidates the file's index entry regardless of its modification time, re-extracts the text, refreshes an open
document, and acknowledges it; it never loads a saved version over a newer file.

## 5. What the Processor guarantees about the file

The candidate is the original byte for byte followed by one incremental revision (pinned static PDFium) whose kept
pages' active object graphs are unchanged (`ReOCRPreservationCheck`); publication keeps the path, the Finder tags as a
multiset, label, other extended attributes, resource fork, ACL, mode, flags, and creation, modification and
date-added times (the inode and change time do change), and keeps a verified copy of the replaced file until the
person removes it in the Processor's history. Encrypted, signed, cross-reference-stream, raw one-page and
non-suite-structured files are refused for in-place improvement.
