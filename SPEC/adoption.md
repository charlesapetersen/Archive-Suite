# Adopting the pre-app archive

Owner call 31 (2026-11-21) moves the archive's legacy conventions into one scratch-first adoption tool: the Red
means Box, Purple means Folder colour reading, the named `Archival Photos` and `Archival Photos JPEGS` trees with
their filename pairing, and the old box and folder label backfill. The tool reads a source tree and writes a
**separate derived archive** in the [catalogue companion](catalogue.md) format, with each matched original in the
[Preservation folder](catalogue.md#preservation-copies). The source is only ever read. Implementation:
`ArchiveProcessor/macOS/Sources/ArchiveProcessor/Adoption/`; commands: `ArchiveProcessor/scripts/adopt-archive.sh`;
self-test: `ArchiveProcessor/scripts/test-adoption.sh`.

The real corpus (`~/Desktop/Google Drive/Archival Photos` and its JPEG tree) is refused as a source, an originals
tree or a destination. Adoption runs on scratch copies. A run against the real archive needs the owner's approval
and is a separate item.

## Steps

Each step is one headless run. A state folder keeps the manifest, the ledger and the reports. It must lie outside
the source, the originals and the derived archive, and is checked before anything is written to it. One step at a
time holds its lock. The source, the originals, the derived archive and the state folder never contain one another.
The real corpus check compares folders by device and inode as well as by path, so another spelling of the same
folder is refused too.

1. **Inventory**, read-only. It walks every PDF under the source, tagged or not, and records its path, size, page
   count, verbatim Finder tags and colour label. It never asks a cloud provider to download a file. It writes
   `adoption-manifest.json` and `inventory-report.md`, and never overwrites a manifest already in the state folder.
2. **Classify**, optional (W49.proc-backfill-classify-optin, owner calls 21 and 31). For an archive whose box and
   folder photos carry no tag or colour, it reads each one-page file the inventory gave no item type, not yet
   converted, with Vision on this Mac, from the matched original or else the PDF's page rendered to a temporary
   file. The Processor's text-only page classifier then judges the text: `vision-heuristic` is its keyword rules ($0,
   nothing leaves the Mac), and `<provider>:<model id>` sends the Vision text, never the image, to that model with the
   user's key. Run alone, it prints the estimated time (Vision timed on up to three of the files, plus the model's
   calls) and the most it can cost (the longest text the classifier sends, a token a character, and the whole reply
   allowance; a Gemini model that thinks gets the lowest thinking budget, which is counted) and changes nothing. It
   runs only when asked, with a cost cap at least that figure; a model whose price is not listed is refused, and no
   call is made that could take the run past its cap. The cap is for one run. A found label becomes a proposed item
   type with rule `classifier:<route>` and waits for review (`type-classified`), even an entry accepted before. Every
   verdict, `document` and `unread` (Vision found no text) included, is kept in the entry's `classified` and saved
   as the pass goes, so a later pass reads only what it has not. A page that could not be read and a model reply with
   no tag are left for a later pass. The keyword rules propose any short page that names an archive or opens with a
   number range, so their findings need checking. It writes only the manifest and its report.
3. **Review.** Each entry has a `decision`: `accept`, `skip` or `review`. Clean entries start as `accept` and
   anything uncertain starts as `review`. A reviewer edits the manifest, or decides a reason group at once (`decide`
   accepts or skips the waiting entries whose reasons all fall in the group).
4. **Convert** files each accepted entry at the same relative path in the destination, which must be new or empty.
   The step copies the PDF with a new catalogue identity (`SearchableArchival.catalogueCopy`: only the identity is
   added) and writes its companion. It preserves the matched original's exact bytes when the PDF has one page. The
   derived PDF carries no Finder tags or colour; its facts live in the companion. A source whose bytes, tags or
   colour changed since the inventory is refused for a new inventory.
5. **Verify** reports every accepted entry that did not land, then re-reads the derived archive through `CatalogueReader`. For each converted entry it checks that the
   pair reads, the companion is the one filed, the page count matches, every proposed fact reads back, a preserved
   original matches its source image, and the source's bytes and tags are unchanged. Convert runs it too.
6. **Labels**, optional. It reads each converted Box or Folder file's label from its matched original (Vision on
   this Mac, $0) and proposes the derived directory's container runs through the shared backfill engine. It writes
   `.archivesuite/containers.json` in the derived archive only, and only when asked to apply. A folder whose files
   are not all converted or skipped is not written, since a run covers the files after its label. A label without
   an original starts its run unread. Reading it from the PDF's first page instead is an explicit option.

## Interruption and repeat runs

Before an entry is filed, the ledger (`adoption-ledger.json`) freezes the entry's whole filing: the operation ID,
the source's SHA-256, the companion bytes, the destination proof and the preservation map. The prepared PDF is kept
in the state folder's `work/` until its pair verifies. A later run repeats the same operation through
`CataloguePairFiler`'s journal and recovery, so an interrupted entry is finished, never filed twice. An entry counts
as converted only once its pair and preserved original verified. A second run over a finished manifest changes
nothing. A bad adoption is discarded by deleting the derived archive and the state folder, then rerunning from the
untouched source.

## Proposed facts

Every fact names its `rule` and quotes its `evidence`. Converted fields have origin `imported`, or `model` for an item type the
classifier proposed, and carry the same rule and quote as evidence. An old `Checked Date` or `Checked Sent With` tag becomes a current check on that date. The tags are read with the suite's own grammar (`DocumentTags`), and the raw tokens stay in
the manifest.

| Fact | Rule |
|---|---|
| Item type (`box`, `folder`) | An explicit `Box` or `Folder` tag (`tag`), else the colour preset (`colour:red-box-purple-folder`). The preset `none` reads no colour as a type. The optional classifier proposes one for an untyped file (`classifier:<route>`, quoting the Vision text). |
| Colour | The Finder label, always kept as display metadata (`finder-label`), even when it also gave the type. |
| Date, Sent with | The date tags (`date-tags`, `sent-with-tag`) with their uncertainty. A Year supersedes a Decade. |
| Subjects | Every other tag, verbatim. A date-like or unrecognised spelling stays a subject. |
| Read state, Quality, OCR Poor | Their tags. |
| Original | `mirrored` (the same relative path in the originals tree) or `stem` (the only original with the file's name), from `JPEGPartnerIndex`. |

## Reasons an entry waits for review

| Code | Meaning | Convertible once accepted |
|---|---|---|
| `type-conflict` | A Box or Folder tag disagrees with the colour reading or with another type tag; the tag the grammar reads is proposed. | yes |
| `date-ambiguous` | More than one token for one date facet. | yes |
| `date-incomplete` | A date token gave no date or only part of one: a Month with no Year, a Day with no Month, an impossible day, or Date Uncertain with no date. | yes |
| `quality-conflict` | More than one Quality tag. | yes |
| `original-missing` | No original found. | yes, without an original |
| `original-ambiguous` | Several originals share the name; the candidates are listed. | yes, without an original |
| `original-unknown` | The originals tree could not be read whole. | yes, without an original |
| `original-shared` | One original is claimed by several PDFs; none keeps it until the reviewer says which. | yes |
| `original-multipage` | One original for a PDF of several pages. | yes, without an original |
| `original-offline` | The matched original is a cloud placeholder; copying it would download it. | yes, without an original |
| `type-classified` | The optional classifier proposed the item type. | yes |
| `pdf-unreadable` | The PDF does not open, has no pages, or is encrypted. | no |
| `pdf-offline` | A cloud placeholder whose data is not on this Mac. | no |
| `pdf-ineligible` | Signed, certified, or otherwise unable to take a catalogue identity unchanged. | no |
| `tags-unreadable` | Its tags could not be read. | no |
| `already-catalogued` | It already carries a catalogue identity. | no |

## Left to later work

`W49.storage-pilot` ran the tool on representative scratch copies with the rest of the catalogue rollout
(`ops/verify/storage-pilot.sh`, rerunnable at $0). The
owner then reviews that pilot (`W49.corpus-adoption-owner-review`), including which old spellings the tag grammar
reads as subjects and whether a label photo without an original may be read from its PDF.
A general folder-map or
filename rule beyond the two pairing tiers above is not included. The historical bench's number, folder and image
tiers (`segbench/corpus_pairs.py`) remain evidence for review. Retiring the apps' legacy paths waits until the owner
has adopted the real archive (`W49.corpus-legacy-retire`). Adopted pages carry the role `page`, as the Processor's
pre-OCRed filings do, and cannot yet be rotated in the Reader (suspect S-066, `W49.proc-s066-verify`).
