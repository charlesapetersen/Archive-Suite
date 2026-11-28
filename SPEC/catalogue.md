# Archive Suite catalogue companion

Owner call 32 selected one authoritative adjacent JSON companion per PDF. This contract is for the
adopted catalogue. [The current tag and PDF format](tag-format.md) continues to describe the existing
app paths during the rollout. [The rollout plan](../execution-plans/storage-simplify.md) covers discovery,
writing, app integration, projections, adoption and recovery. See [field mapping and acceptance cases](catalogue-fields.md)
for the Inspector, Processor output, Notes and Zotero.

## Location and identity

The companion for `Letter.PDF` is `Letter.PDF.archivesuite.json` in the same directory. The entire
filename, including its original extension, is significant. The optional Processor segment JSON is
a different artifact. One adopted root selects one authoritative format. A missing, unavailable,
invalid, conflicting or newer companion must surface its status. Unadopted scans can expose separate,
labelled observations for deliberate adoption. Legacy tags, headers and exports never supply a fallback
current value for an adopted record.

A companion's `fileID` is a stable UUID assigned to the Suite file lineage. `contentRevision` names
one physical content generation. New Suite output will carry these two identifiers in the PDF and
JSON. A pre-app scan may instead have an explicitly confirmed association under the root grant.
The Suite identity property in PDF XMP is `identity` in
`https://github.com/charlesapetersen/Archive-Suite/ns/catalogue/1.0/`. Its text is the file UUID,
one space and the content generation UUID. The property belongs to the PDF's RDF subject. Its
PDF/A extension schema shares the schema list with the page-header extension when both are present.
`CatalogueAssociation.pair` accepts positive evidence obtained independently from the candidate
JSON, scoped to the exact occurrence. It verifies the file ID, content generation and physical page
count. A name, size, timestamp, PDF trailer ID or byte digest alone is insufficient. A companion
must never be applied to a replacement at the same path on name evidence, even after a restart.
A metadata edit changes `revision` and records its direct parent revision IDs. A content replacement
also advances `contentRevision`. App-specific proof acquisition and pair creation are separate rollout stages.

An occurrence is the granted root *instance* and canonical relative path. A move of the entire root
retains the instance and relative paths after the grant is resolved. A simultaneously mounted copy
gets its own instance, even if its on-disk root marker GUID is the same. A paired copy can share all
on-disk IDs and revision history. Its exact occurrence remains distinct and subsequent edits must
be restricted to it. A PDF-only transfer carries no current catalogue. Duplicate files, competing
records and divergent histories are preserved. Discovery has to report unresolved association, rather
than supplying certified evidence for a guessed pair. A later write needs to guard and recheck its
exact occurrence and base revisions. Neither a global UUID lookup nor modification time authorizes
writing to a copy. A PDF-only rename or move may detach the companion and needs explicit recovery.

## What each record owns

| Scope | Values |
|---|---|
| File | `readState`, `flagged`, `colour`, `quality` (1–3), `ocrPoor` (human assessment) and `ocrFailed` (processing outcome). |
| Physical page | Unique `id`, zero-based `physicalIndex`, `documentID`, `role`, optional `sourcePageID` and clockwise `viewRotation` in 90-degree steps. A source image and its transcription page can share a source-page ID. |
| Logical document | Independent `documentDate`, `sentWith` and `publicationDate`, `documentKind`, `itemType`, `title`, ordered `byline`, `publication`, ordered `senders`, `recipients`, `sendingPlaces` and `recipientPlaces`, and verbatim `subjects`. A date-like subject remains a subject. |
| Relationship | An owning document can record `enclosedWith` using the covering document and owner file IDs. The relationship and the independently assessed Sent with date have distinct meanings. |

Every physical page names exactly one document membership in its own companion. A merged PDF may
list several documents. A split logical document has one owning file; its other files carry membership
and the same document/owner IDs. A locally owned membership has a `fields` object, including when
empty. A foreign membership has no fields or enclosure edge. Resolving a foreign owner requires one
verified occurrence of that file ID within the same root instance and a direct declaration of ownership
for the document in that record. Zero matches, multiple matches and an inconsistent owner are distinct
outcomes. A relationship never follows a chain of non-owners or searches another root. If a PDF owns
the requested document locally, its own verified occurrence supplies the fields. A bulk edit targets
file fields per occurrence and document fields once per resolved owner occurrence and document ID.

The PDF carries the original images, OCR text and actual processing provenance. The catalogue's
view rotation is presentation metadata. Container inheritance continues to come from folder/root
records. Local references, bookmarks, indexing, journals and Notes library content belong outside
the companion, as do absolute machine paths and credentials.

## Field values, evidence and extensions

[JSON Schema](catalogue.schema.json) describes the wire shape. Use UTF-8 JSON with unique object
keys, at most 16 MiB and 500,000 values, with values no more than 63 levels below the root. ArchiveCore also checks
semantic constraints such as dense page indices, unique document and page IDs, ownership and valid
calendar dates. The schema number identifies required semantics. An unsupported schema or state
for a known field makes the record unavailable. Optional extension keys and open vocabulary strings
(round-tripped as written) can be introduced without changing required semantics. Common page roles are `image`, `text`, `searchable` and `page` (a pre-OCRed or adopted PDF page without a
Suite image/text split). Common origins are `user`, `model` and `imported`. Unknown roles or origins confer
no edit privileges. Use `read` and `unread` for read state, `box` and `folder`
for item type, and `gray`, `green`, `purple`, `blue`, `yellow`, `red` and `orange` for the current
colour vocabulary. Use a recorded clear for neither read state, no type, no colour or unrated, when
that absence is intentional. Raw names and strings retain international text.

A field's absence is unassessed. An optional null field envelope is equivalent to absence. An
intentional clear is an envelope with `state: "cleared"` and no `value` key. A `state: "value"`
envelope requires its typed value. A date value uses `ArchiveDate` wire strings such as `1950s`,
`1957`, `1958-03` and `1958-03-12` and an independent `uncertain` Boolean. Changing the date or
its uncertainty gives the field a fresh `fieldRevision`. The same rule applies to changing another
field's value or switching between a value and a clear. A check is current only when
`checkedRevision` equals `fieldRevision`. Unchecking removes the check and leaves the current value.
A new machine reading is evidence until accepted. It cannot replace a correction or a recorded
clear on its own, or confer a check. Evidence may name the source, route, run, measurement status,
supporting revision, page, normalized region (source orientation, origin top left), quote and proposed
or historical value.

`CatalogueRecord` retains the original JSON bytes for lossless unchanged export, including optional
unknown data at any depth. The writer patches individual fields, preserving untouched wire values and
revalidating the resulting record. If a change would discard an unfamiliar value extension or overwrite a
field with an unknown origin, it is refused. Record decoding is pure.

## Preservation copies

When Processor keeps originals, the companion also carries `preservationManifestSHA256`. It is the
base64-encoded SHA-256 of the exact `pages.json` bytes. The map and originals live under
`Preservation/<document UUID>/<file UUID>/` beside the reading PDF. The document and file directories use
lowercase UUIDs. A document filed as several reading PDFs can share a document directory when the PDFs
share a parent. Moving the entire containing folder or changing the matched PDF and companion names
does not change the association.

The map contains `fileID`, `sources`, and `pages`. Each source has its original intake `name`,
native `format`, and a `fingerprint` with `byteCount` and base64 `sha256`. The map's `storedNames`
array records one filename per source in source order. Processor uses the filed PDF's base name
and preserves the original extension. For several originals it adds a suffix such as ` - page 3`,
using the first reading page that comes from that original, counting document pages without their
OCR text partners. The filing name stays in the map when the reading PDF and companion are renamed.
Maps without `storedNames` use `source-1.jpeg`, `source-2.pdf`, and so on. All copies use the exact
intake file bytes. Each map page uses the reading record's stable source-page
`id`, zero-based `sourceIndex` and zero-based `originalPageIndex`. Both halves of an image and OCR pair
share one source page. Several derivative pages that came from a single native PDF share one copy and
carry their original physical page indices. A legitimate metadata edit can keep the map by leaving
the source-page IDs and digest intact.

Reader checks the map against the verified PDF and companion inside the archive grant. An explicit
view verifies and uses the same source bytes. Discovery skips the preservation document directories.
The copies supply no extra search rows. No automatic download is requested. A companion with a
digest can report a missing map or source. Where no verified association was recorded, Reader
reports **Not recorded**. A PDF-only transfer leaves the originals behind.
The Processor's Improve OCR reads a page's verified copy the same way, read-only, as the image it sends to the
reader, and falls back to the reading PDF's image with the reason shown ([Improve OCR](improve-ocr.md) §5).

Initial filing verifies the preserved files and their map under the same pinned directory lock
before publishing the PDF and companion. A receipt requires this verification on every attempt. A retry reuses prepared payloads
that match the map and refuses conflicting names. Live Capture retains staged originals until the
verified receipt and its own filed-group record are durable. A hard interruption during a copy can
leave an unfinished hidden temporary file beside the pending directory. It never substitutes for a
verified source. Process Files leaves the intake originals in place. The reading PDF stays PDF/A-2b.
A portable preservation transfer includes the PDF, its companion, and the corresponding
`Preservation` directory. Cloud-provider behavior requires a separate round-trip verification.

## Scoped reads and refresh

`CatalogueReader` runs while the caller holds a successfully resolved, non-stale grant for one
root instance. Full discovery inventories PDFs independent of tags. A caller with an existing scan
can supply its canonical relative paths and say whether the entire root was successfully inventoried.
Extra paths, such as a selected Notes link, are checked under the same grant. Reads reject symbolic
links and aliased spellings inside the root. Hard-linked PDFs and companions are unavailable because
two names can share one physical file. Reads never request cloud downloads. The reader obtains positive
identity from a trusted callback on the open PDF descriptor, independently of the JSON. Production
identity carriers and confirmed-association acquisition are staged with the writer and producer.

`ItemFacts` reports legacy or the selected file's availability and resolves its document from the
selected physical page. A file-only selection of a merged record has ambiguous document facts. File
fields and the selected page stay available when a foreign owner cannot be resolved. A partial
inventory cannot certify a unique foreign owner. Two positively identified PDF occurrences of the
owner file ID are ambiguous even if one lacks a companion. A positively identified PDF whose
companion is unavailable reports that failure for the owner. A PDF whose own bytes are offline
cannot establish an owner ID on a cold scan. Its own row reports offline. If there is no independently
identified occurrence of the requested owner, the split member reports missing owner. An enclosure
resolves from the record declaring the edge, independently of the Sent with date.

The caller publishes refreshed snapshots to `CatalogueFactsUpdates` for that root. A scoped
subscription refreshes on availability changes, content generation or companion revisions, including
changes to a split document's owner or enclosure. The comparison includes a hash of the companion
bytes, so a conflicting record claiming the same revision with the same timestamp still invalidates
cached facts. The hash is an invalidation input and proves no PDF association. Rebuilding a cache
starts with a fresh read. Consumers connect their file-event loops during app integration, where
cold discovery cost and cloud-provider behavior still need verification at the target scale.


## Guarded local saves and recovery

Owner call 32 authorizes writing current catalogue fields to the adjacent companion. The local
`CatalogueWriter` is the single boundary for editing an existing companion in a granted adopted root.
It holds an exclusive lock on the already open parent directory for each operation. It checks the root,
exact occurrence, physical PDF version and independent PDF identity again at save. Copies with the same
embedded IDs, and identical bytes at a replaced path, cannot use the original selection as a write grant.
The writer does not open the PDF for writing or alter its tags, content or location. It also refuses
unsupported, stale, offline, read-only and invalid inputs without inventing a replacement record.

Edits address file fields, fields of a locally owned document or an individual physical page's view
rotation. An intentional field clear gets its own revision. Resetting a page's view rotation removes
the override without changing the PDF's intrinsic orientation. A change to a value or its uncertainty drops the old check and retains historical
evidence. Checking or unchecking keeps the field revision. A batch targets each field once. If the
base is stale, the live record must be linked to the exact base bytes through retained local exchanges.
The writer then compares the complete touched field envelopes, including checks, evidence and
extensions. Disjoint edits can be saved from the same base through multiple revisions. An overlapping
edit or an unverified branch returns the current record and the user's proposed record for explicit
reconciliation. A record revision UUID alone does not establish ancestry.

The writer creates a new, exclusively named sibling, copies the companion's filesystem metadata, flushes
the new data and verifies it before atomically exchanging the two names. It verifies the published
candidate, displaced before-image and the original PDF occurrence afterward. The hidden sibling name
encodes SHA-256 digests of the PDF's local identity and filename, the old record and the candidate. This lets a later session
distinguish a staged candidate from a completed exchange and identify divergent or incomplete operations.
These artifacts are recovery history. The adjacent companion remains the sole source of current facts.
A whole-folder copy that includes hidden files also carries those historical records. A pair transfer
carries the PDF and active companion. A missing or invalid live companion is still unavailable. Recovery inspection can show a retained record
when the PDF independently proves its identity. It never promotes an artifact automatically.

Each successful exchange retains one exact before-image. Interrupted or uncertain exchanges retain the
available bytes for reconciliation and report the artifact name. Retaining those files also permits
verified disjoint edits from earlier bases. There is no automatic pruning during the rollout. A future
retention policy would have to account for open edit bases and Undo. Coordination applies to local
writers using this boundary. The writer attempts to restore a racing external version when it can still
verify both exchange names. Changes outside the lock can leave an uncertain outcome, so both versions
are kept. Network mounts are refused. Provider synchronization and multi-device writes require their
own verification.

File ▸ Use Catalogue Companions for This Folder selects catalogue mode for the open physical root on
this Mac. In that mode Reader lists PDFs independently of Finder tags. Outside it, a scan counts the companions it
sees, and an empty list in a folder that has some offers the mode. Reader records each attempted
companion change in local application support before saving and records
its verified result afterward. One user action groups distinct companion occurrences. Document field
edits address their resolved owner and document ID once even if several selected PDFs refer to it.
Undo and Redo compare the exact targeted envelopes against verified before and after records, then
apply only the inverse changes. They preserve unrelated values and refuse a changed target or PDF.
An interrupted save with an uncertain result withholds older Undo for the affected occurrence while
verified changes to other occurrences remain available.


## Repair after a Finder rename

A same-folder PDF rename leaves the current companion detached until a confirmed repair succeeds.
`CatalogueWriter.reassociateCompanion` takes a verified pair from before the rename and the observed
new path. It requires the same granted root instance, the same physical PDF and independent proof
of the same file ID, content generation and page count. The former PDF name must be vacant or an
alternate spelling of that physical file. The former companion must still be the exact file and
record in the verified pair. An occupied destination or an indistinguishable PDF copy gives an
ambiguity result. An absent companion still reads as missing. Discovery never attaches an orphan
by filename, timestamp, digest or embedded identity alone.

Under the same local parent lock used for saves, the writer exclusively renames the unchanged
JSON and verifies both paths before returning a receipt. Case-only repairs work where the filesystem
supports that exclusive rename. Undo verifies the PDF and the exact companion from the receipt,
then returns the companion to its former name. The PDF stays at its Finder-chosen name. Later
corrections, another occupant or a changed scope can refuse Undo. Discovery and repair leave
historical edit artifacts at their original names. Those artifacts use the original PDF name in
their lookup key. An outside writer that races the repair can leave an uncertain outcome, in which
case the writer reports both companion names for inspection and never overwrites either one.

Reader remembers the physical identity and companion digest of previously verified pairs in its
local application support. After relaunch it checks the renamed PDF and former companion before
offering repair in the Inspector. The user confirms the new companion name. The writer repeats the
checks before the rename, and Edit ▸ Undo and Redo verify the paths before changing them again.
Without a remembered, verifiable pair, or after a cross-folder move, the names need manual review.


## Journaled initial pair filing

`CataloguePairFiler` files a new derivative in an adopted local root. The producer persists one operation
UUID, the grant's root-instance ID and the final PDF's exact root-relative path before starting.
It prepares a finished PDF under the operation's hidden pending name beside that destination,
supplies the initial companion record, and holds the root's grant. The identifying callback reads the PDF descriptor independently of the companion
even at the pending name. The caller keeps the original input and is responsible for its own retirement
ledger and all other retirement checks.

A producer with a prepared working PDF can supply its URL and the physical destination proof saved
with the request. The filer exclusively stages a copy under the granted directory lock and verifies
its identity and bytes before claiming the reserved pending name. It compares resumed pending bytes
with the working copy if a journal has yet to be written. A replaced root or directory with the same
path fails the saved proof. The working PDF remains available until the producer acts on a receipt.

Under the catalogue parent lock, the filer verifies and flushes the staged files and writes a hidden
journal containing their pending and final names, physical identities and SHA-256 digests. The journal
also binds the operation to the granted instance and the physical root and parent directory.
The filer flushes the journal before claiming either final name. It claims each name exclusively, reopens and verifies the pair, then renames
the journal to a completion receipt and flushes the directory before returning. The PDF's bytes and
filesystem metadata travel with the staged file when its name changes. The copy leaves the working PDF's
Finder tags and label (`com.apple.metadata:_kMDItemUserTags`, `com.apple.FinderInfo`) behind unless the producer
asks for them (`carriesFinderTags`), and so does the Finder mirror's ownership record. Its other extended
attributes are copied either way. Finder tags mirror the companion only when the archive turns that on (owner,
2026-11-27, `W49.storage-finder-owner-ok`: off everywhere by default; adoption leaves an original's tags behind).
The Processor asks for them when the destination's archive mirrors (its settings document), or outside any archive
when its general setting `mirrorFinderTags` is on, frozen with each filing request
([the suite's Finder mirror](tag-format.md#the-suites-finder-mirror-w49storage-finder-reader-mirror)).

After interruption, use the same UUID and destination to recover the journaled operation. Recovery
recognizes either exact member at its pending or final name and can finish a missing rename. A completed
receipt is reverified against both files on each retry. A missing member, a different file at either name,
a changed digest, a damaged journal or unverifiable scope withholds success and retains all available
files for reconciliation. If the journal was never created, the producer can retry preparation with
the same staged PDF and record. Unusable partial staging or journal bytes require reconciliation. The
caller keeps the original input and can use a fresh operation once it confirms the destination names
are free. Filing uses exclusive destination names throughout and leaves source retirement to its caller.

The journal is local recovery data. A portable pair is still the final PDF and active companion. The
protocol coordinates same-directory local writes through ArchiveCore. A receipt reflects the files
at verification time. External writers can race a rename of a reserved staging name. The filer then
withholds a receipt if the resulting files differ from the journal and leaves the available artifacts
in place. Cloud synchronization and multi-device transactions need their own verification.
Live Capture uses the receipt in its existing filed-group ledger and source-retirement checks. It keeps
the destination and operation IDs in the staging manifest so a repeated Finish can resume the same
numbered filing. Optional image and segment JSON exports stay separate.

## Pair and subset export

`CatalogueExport` copies selected PDFs and their companions into a new folder outside the granted root,
byte for byte, keeping each file's root-relative path. It also copies whatever the selection's documents
depend on. That includes the owner and every other member of a split document, the owner of an
enclosure's covering document, and the verified `Preservation/<document>/<file>/` map and originals.
It also copies each ancestor folder's `.archivesuite/` container, level-map, container-name and
collection-settings records, from the root down. It does not copy root markers, journals, receipts or
other local state. Reader offers it as Selection ▸ Export with Catalogue Records….

The export is all or nothing. Nothing is published if a needed file cannot be read as a verified pair,
if an owner is missing or ambiguous, or if a preserved original is missing or damaged. It is also
withheld when an owner of a split document is selected and any other companion in the root cannot be
read, since that companion could be an unreadable member. Each file is copied from the descriptor that
was verified against the scan, and its companion must match the scanned bytes. Files are written
exclusively into a hidden staging folder beside the destination. The staging folder is then read back
as its own root and must show the same records and document owners. Only then is it renamed to the
destination without replacing anything. The destination may not be the archive folder or lie inside it.
Its ancestors are compared by device and inode.

`archivesuite-export.json` labels the folder a snapshot. It records the creation time, the archive
folder's name and root instance (no machine path), and each file's role (`selected`, `document` or
`enclosure`), IDs, revision and SHA-256 digests. It also lists the context records and preservation files
that were copied. Opened as a root of its own, the folder is a separate occurrence: its records never
update the archive's, and later archive edits do not update it. `contents` is `whole-records` for this
export: each companion travels whole, including read state, flags, colour, quality and checks.

A sharing copy (owner, 2026-11-27, `W49.storage-export-share`; Reader: Selection ▸ Export Sharing Copy…) is
the same export with `contents: "disclosure-limited"`, for sending to someone else. Each companion is
derived from the archive's: `fileFields` keeps only `ocrPoor` and `ocrFailed`, so read state, flags, colour,
quality and any unrecognised file-level field are left out and read as not yet assessed, never as a recorded
clear. `checkedRevision` is removed from every remaining field envelope. The record gets a new `revision` and
no `parents`, since it is not part of the archive record's history. Descriptive fields, their evidence and
field revisions, and unrecognised keys outside `fileFields` keep their wire form. The manifest's `omitted`
lists what was left out and its note calls the folder a disclosure-limited snapshot. Verification derives
each record again from the scanned archive record under the manifest's revision and requires the same bytes.
PDFs, preserved originals and folder records are copied byte for byte as in the whole export; OCR text and
PDF headers can still disclose what they contain.
