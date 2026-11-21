# Where item facts should live — decision analysis

W49.storage-model-analysis and W49.storage-metadata-review · 2026-11-21. The original source survey used `4bffed3d`. The new scratch measurements are in §12.

**Recommendation: one authoritative JSON companion per PDF, Reader fields for viewing and changing its facts,
and optional Finder-tag and Spotlight projections.** Keep transcription and the record of how it was made in the
PDF; take editable catalogue facts off newly generated page 2. This fits the owner's call 29: transferable to
other apps need not mean immediately understood by them. It has one substantial price: an ordinary PDF-only copy
or Finder move does not carry its companion. If that must always work, choose embedded structured PDF metadata,
or a document package, instead. No filename, watcher or UUID in the JSON alone removes that price.

This is a proposal with synthetic scratch evidence, **not an approved format or permission to convert anything**. No app, SPEC,
setting or archive has changed. It replaces the options and recommendation in the 2026-11-20
W49.storage-simplify-audit version of this file (history: `8d8d16e1`). The existing gate
`W49.storage-one-home-owner-ok` remains unanswered. The decision is in §9; refactor sizes and verification are
in §10–§11. Repository links name symbols as well as files so the baseline remains inspectable.

## 1. What changed in the question, and what exists today

Owner calls 24–25 questioned putting editable fields on page 2 and invited reconsidering Reader's never-rewrite
rule. Call 26 asked for one home per fact. Call 29 rejected the earlier analysis as insufficiently deep, leaned
away from the Finder-tag scheme toward a sidecar, and asked for specific Reader fields plus Spotlight and Finder-tag
settings. Authority: [owner calls](processing-review/13-stage-rules/14-owner-calls.md), especially call 29. A lean is
not approval of this recommendation, its defaults or its limitations.

The earlier survey's requirement that every other app directly see every correction pushed it toward PDF writes.
That is no longer the right deciding criterion. A documented UTF-8 JSON record can be straightforward to convert
without Preview or DEVONthink knowing the schema. Also, a historical observation and a current field are different
facts: keeping provenance is useful; letting an old observation compete with the user's current answer is not.

| Current location | Actual role and readers at this baseline |
|---|---|
| Finder tags / colour label on each file | Current dates, subjects, Quality, item type, Read/Unread, OCR Poor/Failed and field checks. Reader discovery itself requires Read/Unread. Reader, Processor, Notes source-date suggestions and Zotero consume tags. |
| PDF text page (usually page 2 of an image/text pair) | OCR text; actual reader/model/time; source name; segmentation classification and reading kind; optional date/evidence and item-field headers. Reader parses headers; external full-text tools may index the text. Reader corrections do not update these bytes. |
| PDF XMP `archivesuite:pageHeaders` | The same per-page header for the searchable form, which has **no separate text page**. It is not an independent current item store. |
| Processor `<basename>.json`, beside the PDF or in `JSON Output/` | A **segment** export: source-file list and OCR body, generated dates/subjects, entity names/evidence, dating and item fields. Names are read by Reader's Inspector **and content index**, Notes/Reader Zotero gathering. Sidecar item-field fallback is also read by Zotero. Thus “the sidecar has no reader” is false for the whole file. |
| `.archivesuite/item-fields.json` per folder | Name-keyed user corrections (including explicit empty answers) and accepted folder-date evidence. Reader/search/Zotero apply these over the generated fields; Processor re-runs do not consume them. |
| `.archivesuite/containers.json`, level/name maps, collection settings and run records | Shared folder/collection facts and processing settings. Their inheritance has meaning; duplicating it into every item would create stale copies. |
| Reader settings and SQLite caches | Flags and page rotations contain user choices keyed by absolute path; other index/thumbnail data is rebuildable. A root move and a file rename are separate problems. |
| Notes `.archivenotes` library | Its notes' front matter is authoritative; Finder tags on those Markdown files are already projections. Source-PDF metadata is read from the archive, not owned by the note. |
| Capture relay, manifests, staged outputs | Recovery state until verified filing, not another long-term metadata authority. |

Sources: `CorpusWalker.tracksReadState`; `PDFGenerator.headerBlock`; `PDFHeaderCarrier`; `SegmentJSONBuilder.buildData`;
`ZoteroSidecar.locate/read`; `UserItemFields`; `FieldStatusSection.HeaderFields.read`; `IndexedItemFields`;
`ZoteroSource.gather`; `RoundupYearSuggestion.readYear`; `NotesTagProjector`. Full paths are in §11.

A further distinction matters: today's sidecar is **optional output**, and a segment can cover several PDFs.
Making JSON canonical means neither retaining that optional-export switch nor assuming that every old JSON file is
already a complete per-PDF record. Live Capture currently files the segment JSON under its first output's number.
A canonical store must cover every output, not just the first page's file.

## 2. One current answer, with evidence attached

The storage decision should separate four kinds of information:

| Information | Recommended home under the companion option | Reader treatment |
|---|---|---|
| Document date, precision, uncertainty; Sent with and its uncertainty; publication date | Companion, distinct typed fields and roles | Visible and editable. A change to one role never overwrites another. Derive sort keys; do not store another date merely for sorting. |
| Subjects, Quality/importance, Read/Unread/neither, Box/Folder item type, colour, OCR Poor, flag | Companion | Named controls and filters, including unrated, neither and no colour. Preserve free-form subjects without interpreting a date-like subject as a date. Separate OCR failure from a person's OCR Poor judgement. |
| Document kind, title, byline, publication, sender(s), recipient(s), sending and recipient places | Companion | Specific fields; structured lists for names rather than one ambiguous joined string. The current semicolon display can remain a presentation choice. |
| Checked status, evidence quote/location, source of a value, route and available measured/evidence status, user correction | Alongside its field in the companion | Check applies to the current value/revision. Show why a value was inferred and what was measured; a user change must not keep an unrelated model confidence. |
| Page order/roles, document membership, enclosure relationship and page view rotation | Companion, with explicit page/document identities | Display and correction actions where appropriate; view rotation does not secretly rotate the underlying PDF. Store relationships by identity, not a covering letter's basename. |
| OCR transcription, image content and actual per-page reader/model/time | PDF content and its processing header/XMP | Readable in the viewer; expose provenance in fields. Correcting a catalogue fact does not require re-OCR. Improve OCR remains an explicit content-revision workflow. |
| Collection/series/box/folder/repository and collection settings | Existing folder stores | Show inherited values and their source; edit at the correct level. An item override, if offered, is explicitly an override, never an unnoticed flattening of inheritance. |
| Thumbnail, full-text index, derived chronology and resolved path cache | Local disposable cache | Rebuildable from content plus current facts. No unique user value lives only here. |
| Preferences, device grants, pending operations and undo journal | Settings/local operational store | Not portable item facts. Pending projection work and undo are not a second answer to a field. |

The exact JSON names are a later contract decision. The necessary semantics are already clear: a record identity;
association with a specific PDF occurrence/revision; current field values; explicit “none”; provenance/checks;
page/document relationships; and a record revision for concurrent edits. Unknown, empty and unreadable are different.
Absent inferred information must not erase a user's explicit empty answer. Unknown structure must be preserved or
refused on write, never silently discarded.

For example, changing the date from 1958 to 1957 should leave one current date, marked as the user's, with a check
for that value. Evidence that the model originally read 1958 may stay in history, clearly bound to the old answer.
It must not be another fallback date. Removing the check changes its status, not its value. Clearing the date stores
an intentional absence; a later Processor run must not refill it without acceptance. A deliberate “use new reading”
action is different from erasing the user's correction and hoping an older copy resurfaces.

A generated observation may be retained for audit or re-evaluation, but it is not an override layer that every
consumer resolves independently. All apps ask the same shared facts reader for the current result. That is the
simplification; eliminating useful evidence merely to reduce the count of stored strings would not be.

## 3. What belongs on page 2, and what does not

**Keep the document readable on its own.** A new image/text-pair output still has its image and complete
transcription, including document dates and names that occur in the transcribed source. Removing a catalogue
header must not remove those words from the transcription. A searchable output retains its text layer. Keep the
actual reader/model/run date and source-page provenance; the processing date must never masquerade as the document
date. Preserve per-page identity/roles and classification observations needed to explain the reading and segmentation.
The searchable form carries the equivalent processing information in XMP, not a fictitious page 2.

**Move current editable catalogue fields to the chosen authoritative store.** Under the companion/folder/package
options, newly generated headers stop printing current Document date, Sent with, date-evidence-as-current-answer,
Document kind, Title, Byline, Publication, Publication date and Recipient place lines. Sender and recipient should
not be newly added to the header as another current copy. Full evidence belongs beside its field, rather than
being cut to a one-line PDF header. The Reader presents all these values without requiring the user to read JSON.
This is a location change for the features, not a proposal to withhold them.

Classification has two uses that must stay distinguishable: what the pipeline detected on a page, and the user's
current document grouping or Box/Folder decision. Reading kind (handwritten/typed etc.) also differs from catalogue
document kind (letter/memo/clipping). Keep the original processing observation with the reading; let a correction
live in current metadata and, when it affects segmentation, pass through an explicit regroup/reprocess action.
Actual model identity is read-only history; a user cannot “correct” it into a claim that another model read the page.

Old PDF headers are historical extraction snapshots once a canonical record is adopted. Reader field search,
filters and exports use the canonical values. Full-text search may still match the old header words if it indexes
all PDF text; field queries must not, and a text hit must be described as PDF text rather than a current field match.
A conversion may separate recognized headers from the OCR body in its index without rewriting originals. Do not
silently strip an ambiguous source line such as a letter beginning “Title:” using a prefix alone.

**An ordinary copied PDF:** Preview sees the image, transcription and processing history, but no later companion-only
corrections. DEVONthink/PDF full-text search sees the same bytes, subject to its importer; it does not acquire the
current sidecar fields by magic. A suite export can create a **new** PDF with a dated current-metadata cover/text
sheet and/or structured metadata, or export PDF+JSON+resolved folder context in a ZIP. Label it a snapshot. Editing
Reader fields later does not update that exported copy, just as it does not update an earlier Zotero export.

If the owner chooses embedded metadata instead, current fields can live in structured XMP without rendering each
one on page 2. “In the PDF” does **not** require “hard-coded as visible header lines.” A metadata panel can read XMP;
a page-2 rewrite is an additional publication choice. This is a materially better embedded option than the old A.

## 4. Which vehicle is best?

All estimates below are reasoned scopes, not measured implementation times. Each route has one canonical facts
API and optional projections. Containers remain folder facts under every route.

| Route | What travels naturally | Editing and recovery | Refactor size / main cost |
|---|---|---|---|
| **S — one JSON companion per PDF (recommended)** | PDF+JSON copied together, a whole folder, or a suite export. PDF alone omits current facts. | Small metadata writes; one item's conflict/corruption does not block a folder. Pair association is a real subsystem. | **L**, cross-app. Most natural match to the owner's lean and easiest documented interchange; many small filesystem objects, cloud round trips and pairing work. |
| **F — per-folder canonical item store** | Whole folder with hidden `.archivesuite`; suite subset export must extract records. An individual PDF loses its facts. | Reuses the existing safe folder-store mechanism; one file is a shared lock/conflict/corruption boundary for many items. | **L** overall, though the storage writer itself is smaller than S. Does not avoid consumer/discovery work. Best if folder-level operations dominate and single-item sharing is rare. |
| **E — structured current facts inside the PDF (XMP)** | Ordinary copies, renames and moves of the unchanged PDF carry the facts. | Every field edit writes PDF bytes; large-file/cloud churn, permissions, signed/encrypted files and third-party rewrites must be addressed. | **XL**, highest safety burden. Avoids separate-file pairing, but requires the Reader PDF-write contract, verified writer and content undo. |
| **P — document package holding PDF+JSON** | The package, when moved/copied as one Finder object. Extracting its PDF alone loses current facts. | Small JSON edits, strong outer pairing; a package is a directory and can still be split by other tools. | **XL**, because the main document becomes a package: import, discovery, opening, links, upload, Zotero attachment and export all change. |
| Central app database | Its library backup or deliberate export, never an ordinary PDF copy | Good local transactions, but a broken/missing library cuts off all metadata; proprietary app dependency | **L–XL**. Poor match to transferable files. SQLite is useful as a cache, not the only durable answer. |
| Custom extended attribute | Operations/transports that preserve attributes | No filename pair, but repeats the platform/transport dependence of Finder tags | **M–L**, still needs all consumer changes. Reject as canonical portable store; useful only as a local association hint. |

A plain JSON record is easy for a script or another app to convert: publish field meanings, date roles and precision,
list ordering, absence semantics, evidence/status and relationship semantics. It needs no suite installation to
recover the information. A human-readable example and a lossless export are more useful than inventing CSL-JSON as
the master format: CSL cannot faithfully hold page structure, read state, checks, uncertainty and every relationship.
Zotero/CSL remains one export mapping.

For S, use a recognizable companion name such as `letter.pdf.archivesuite.json` (illustrative, not a settled
extension), with one location beside the file. Retire the current beside/`JSON Output` ambiguity for **new** canonical
records. Do not call the old segment export the new format: it repeats OCR text, lacks user state and may describe
multiple PDFs. The canonical companion need not duplicate the OCR body; include it only in a self-contained export
when requested. A sidecar-only delivery must say whether it contains text or just facts and a PDF reference.

Per-PDF records make file operations understandable, but a historical document may span PDFs, and one PDF may contain
several document units. Use explicit document/page IDs and membership references; document-wide fields have a named
owning record, with other page files referring to it. Do not copy one document date into N independently editable
records. For the normal merged document there is one PDF and one record. For split output, export/copy the complete
linked document set, or materialize an independent subset with resolved metadata. Discovery shows a missing owner or
incomplete set, rather than silently borrowing the first file's values. This extra structure is part of S's L size;
“one JSON per file” alone is not a complete design. At roughly 102k PDFs, one companion each means roughly
102k more filesystem objects before exports or history; that is a count, not a measured sync cost. Measure cold
discovery and cloud metadata round trips on scratch before selecting eager loads or a per-folder cache.

For F, key records by durable item identities with path hints, not just last filename. Rename/move reconciliation
is still needed. F does reduce sidecar clutter and can make document-unit ownership more natural, but moving one
file to another folder is now a cross-store transfer. If robust ordinary PDF-only sharing is the requirement,
neither F nor S satisfies it; S merely makes an explicit pair/subset export simpler.

For E, custom XMP is the preferred investigation, not embedding arbitrary JSON attachments and assuming today's
PDF/A-2b validator will accept them. `PDFHeaderCarrier` already declares a custom XMP extension schema, but it is
only a header carrier. A new current-facts schema and writer must prove PDF/A conformance and preservation. Third-party
“print to PDF,” OCR or sanitization may discard custom metadata; embedding improves ordinary file portability,
not survival of every transformation. Non-PDF images would still need a companion or a different embedded format.
A fallback sidecar for them is an additional persistent route.

## 5. Pairing through Finder operations: the unavoidable limits

**A sidecar UUID identifies the record, not the PDF.** `FileIdentity` uses `fileResourceIdentifier` as an in-session
write guard; it is not a portable serialized ID. Apple explicitly says that resource identifier is not persistent
across restarts ([Foundation documentation](https://developer.apple.com/documentation/foundation/urlresourcekey/fileresourceidentifierkey)).
The existing root marker identifies a root, not its items. Existing durable links use root GUID + relative path,
with Notes' bounded same-basename fallback; neither resolves an arbitrary rename of a leaf file.

| User operation | S: companion | F: folder record | E: embedded | P: package |
|---|---|---|---|---|
| Rename the document in Finder | PDF-only rename detaches the name pair; recovery needs verified association. Rename both and they stay together. | Store remains; reconcile the record to the renamed object. | Facts stay in the file. | Rename outer package; interior association stays. |
| Move within the same volume | Moving PDF alone leaves JSON; local bookmark/identity may help locate it while access exists. | Same-folder rename is easier; cross-folder move leaves the record in the old store. | Facts move with the file. | Outer package moves as a unit. |
| Move/copy across volumes, cloud providers or to another computer | Transfer both, or lose the record. Local identity/bookmarks cannot supply what was omitted. | Transfer relevant store records/context; folder copies carry the store. | Unchanged data-fork copy carries facts; xattrs are unnecessary. | Transfer complete package; test destination's treatment of directories/packages. |
| Duplicate an item | Pair copy contains same logical ID; separate occurrence/revision decisions are needed. PDF-only duplicate has no record. | Copied PDF alone has no new record. Folder duplicate copies IDs too. | Embedded UUID also duplicates. | Package duplicate duplicates IDs too. |
| Email/upload a PDF alone | No current facts beyond the PDF's own text/snapshots. | Same. | Current embedded facts travel; recipient still needs a reader/converter for custom fields. | Extracted PDF loses companion facts. |
| Re-save or Improve OCR | Verify the old association, then update the resulting PDF revision and record together through the suite operation. | Same, with store transaction. | Verify metadata survives the rewrite. | Update interior PDF and JSON recoverably. |

No recommendation promises that Finder automatically moves a JSON companion. A watcher only sees events while it
runs and has access; events are hints to re-check, not durable proof. A local security-scoped bookmark can be a
recovery aid, not interchange metadata, and cannot grant access outside the user's approved root. A content digest
can find exact-byte candidates, but two identical scans can legitimately have different catalogue contexts. It
also changes after OCR/content revision and can download a cloud placeholder. Name+size+mtime is weaker still.
Never attach or overwrite a correction on these hints alone when identity is ambiguous.

A sensible S implementation has three levels:

1. **Created output:** assign a logical document/page identity at creation and carry a small identity in the new
   PDF's XMP as well as the JSON association. This is an identifier, not a second current-facts store. Do not use
   PDF trailer IDs or source filenames as if they were suite item identities. Verify both outputs before filing
   success and source retirement. Writing a tiny ID to a PDF being created is different from rewriting an existing
   archive merely on selection.
2. **Within a granted archive:** use cached bookmarks and fresh file guards to follow a proven same object;
   detect replacement under an old path. Any persistent companion-name repair is a named metadata-write operation
   with undo/error reporting, not an invisible write from discovery. Prefer offering reassociation when doubt
   remains. Missing/malformed/mismatched records must be visible and preserved.
3. **Across archives or for pre-app PDFs without an ID:** import/export the pair or ask the user to associate the
   record. A deliberate association can create metadata without changing the PDF. A same-name replacement must
   not inherit the old user's corrections. If no positive binding is available after restart, require confirmation
   before applying/writing those corrections; there is no honest zero-write, zero-prompt universal solution.

Distinguish a **logical document ID** from an **occurrence** (this copy in this root) and a **content revision**.
Read-only copies may share a logical identity. Independently editing one copy should fork its occurrence/history
explicitly, never mutate all other copies that happen to carry that UUID. Deduplication or synchronization is not
part of a basic storage refactor. A copied root also copies its root marker; do not assume a GUID alone distinguishes
two mounted replicas. Keep ambiguous replicas separate and surface link ambiguity.

Subset export must carry resolved container context or include the relevant folder records. Otherwise the dates
may travel but the repository/box/folder citation does not. Export records retain their origin and relationships;
opening a detached export must not automatically overwrite a same-ID live record. These rules apply to E and P too,
not just to JSON companions.

## 6. Reader fields, the other apps, and the write contract

The Inspector is already a useful base: `TagEditorView` has subjects, dates, checks/item fields, containers, Quality,
type, read state and flags; `FieldStatusSection` shows evidence and corrections. The change is to make that a
coherent presentation of one effective record, not expose “tags versus header versus correction file” as the user's
job. Show processing provenance and page relationships there too, with compact details for evidence/history.
Missing, mixed, explicitly empty, detached, conflicting and unreadable states need distinct wording. A metadata
problem must not look like “this item has no date.”

Keep the established editing rules: Return/blur commits; an emptied edited field clears; untouched mixed fields
write nothing; invalid text remains with a hint; binary flags are checkboxes; bulk edits and Undo act as one user
action while reporting per-item failures. User choices must survive a crash and concurrent edits. Page view rotation
and flag become metadata under S/F/P, so they follow a correctly transferred record without rewriting images.
E may store view rotation as metadata too; changing actual PDF page rotation is a separate content operation.

A proposed ArchiveCore **ItemFacts** API returns typed current values, status/evidence and a storage/revision stamp.
Reader Inspector, list/sort/filters, content index, Processor re-run policy, Notes source-date suggestions and Zotero
gathering all consume it. A canonical record that is unreadable/conflicting must not silently fall back to stale
tags or page-2 values. An unadopted file is different: show available observations labelled as unadopted, and let a
deliberate adoption/edit create a record. Reader discovery must list such supported files under explicit archive
scope, not make them disappear because tags or sidecars are missing.

Today `CorpusWalker.tracksReadState` admits only Read/Unread-tagged files. Turning off Finder writes without changing
that rule makes new outputs vanish from Reader. The new membership rule, dataless-placeholder handling and cache
invalidation are core work. A metadata-only field edit invalidates all relevant row/index values even though the
PDF's mtime and bytes have not changed. Reader keeps its own search; neither optional external projection may be
required for it to work. Root-relative cache keys help whole-root moves, but do not solve leaf renames or metadata
association; disposable caches may be rebuilt, whereas flags/turns may not be discarded.

**Processor:** every output route creates/updates the canonical record, even when optional JSON export or Finder
projection is off. The entity-call guard tied to today's `enableSegmentJSON` must use the new capability. Process
Files, pre-OCRed input, merge/split, Live Capture Finish, batch/resume, Retry and Improve OCR all need the same
commit/recovery rule. A re-run preserves explicit user values, intentional empties, checks and user read state;
new extraction is a candidate, not permission to replace a correction. Split/merge creates explicit new membership
and reconciles old facts instead of copying checked tags onto unrelated output pages. Canonical-record failure is
an output failure; an optional tag/Spotlight failure is a separately reported projection failure. The latter must
not cause data to disappear or turn a saved record into an apparently failed transcription.

**Notes:** its source Copy/Add to Zotero goes through `ZoteroSource.gather`; `RoundupYearSuggestion.readYear` reads
Finder dates directly today. Both must use ItemFacts, while Notes remains **read-only on the archive**. Its own
Markdown front matter stays authoritative for its own notes. A copied source's metadata is not a new copy of the
note's metadata. Existing source links still need their root grant and rename-resolution work; JSON by itself does
not repair those links.

**Zotero:** current dates and subjects come from `DocumentTags`, fields from user > header > sidecar, names from
sidecar/user corrections, and containers from folder lookup. Replace that gathering with the canonical effective
record; retain the existing type/author/date-role mapping. Export must be identical with Finder tags and suite
Spotlight publishing on or off. Attachment/file sharing is separate from CSL metadata: attach a plain PDF when
requested, export the companion/context separately for lossless suite transfer. Updating Reader later does not
synchronize an existing Zotero item. No automatic two-way Zotero sync is implied.

**Safe metadata writing under S/F/P:** extend the existing descriptor-relative, no-symlink, locked/stamped,
write-temporary-verify-replace discipline of `ContainerFileStore`, with explicit size bounds and preservation of
unknown/unreadable records. A read error is not permission to create an empty replacement. Cross-process stale
writers refuse/reload; undo checks expected field revisions and preserves unrelated concurrent edits. A projection
has its own retry/ownership state; failure must not roll back the current facts or resurrect an older answer.
PDF+record creation has no single atomic filesystem transaction: journal the pair, verify both and recover partial
completion before considering the output safely filed. Existing source-retirement guarantees remain mandatory.

**Safe PDF writing under E:** requires an explicit change to Reader's Core Directive, SPEC invariant and write-surface
lint, plus one audited ArchiveCore writer. Generate beside the original, verify page structure, image/content/text
preservation, PDF/A where applicable, unknown metadata, tags/colour and identity, then coordinate replacement. Retain
recoverable prior bytes for Undo, with bounded storage and a conflict-aware restore. Handle a file open elsewhere,
read-only/encrypted/signed files and cloud placeholders without corruption or invisible downloads. Copy-on-write
metadata changes still replace a PDF's bytes; calling them metadata-only does not exempt them from this work.
The Processor's existing writer is a starting point, not proof that arbitrary originals are safe to re-save.

## 7. Finder tags and Spotlight: two independent settings

Use **one current-facts path** with zero, one or two output projections. Do not have “tags mode” and “sidecar mode”
with different authorities. Four projection combinations require testing, but they need not double every domain
rule. The canonical record works on a filesystem that does not preserve macOS attributes.

### Finder tags

Proposed label: **“Mirror archive fields to Finder tags.”** It changes publishing, not where fields are saved.
Recommend off for a newly created archive under S, subject to the owner's choice; keep today's behavior until a
choice is made. Store the archive's intent with its collection/root settings so the three apps do not disagree;
keep machine-specific access/availability local. Multiple roots can choose separately.

| Change | Necessary behavior |
|---|---|
| Turn on for new output | Derive the existing date/subject/Quality/read/check/type vocabulary from current facts; colour is its own explicitly chosen projection. Record exactly what the suite introduced. Preserve unrelated tags through the audited writer. |
| Turn on for an existing archive | Preview disagreements and scope; adopt existing tag values deliberately before first projection where no canonical record exists. Never overwrite current facts from old tags merely because projection was enabled. Backfill is bounded, resumable, cancellable and reports partial failures. |
| Turn off | Stop future projection. Existing tags remain unless the user separately chooses removal. Explain that they can become stale; stopping writes alone does not make Finder match the current fields. |
| Remove old suite projections | A deliberate, undoable cleanup, using recorded ownership/deltas. Do not delete every recognized year, Q token or Read tag: hand-authored and subject-colliding tokens are not all suite-owned. Old files without an ownership ledger need an explicit reviewed reconciliation, not guessed ownership. |
| Someone edits a mirror in Finder | Detect/report divergence; offer deliberate import or re-publish. Do not silently make Finder a second authority. This changes today's ability to make a Finder edit immediately become Reader truth and must be part of the owner's choice. |

Projection and current-facts success are reported separately. Undo edits the current record, then projects the new
result if enabled; it never restores a whole stale tag array. The existing `CoordinatedTagWriter` remains the only
tag-write seam. Colour and tags already on originals remain untouched unless the user authorized that operation.

Notes' own note tags are a separate scope. Offer a separately named **“Mirror note fields to Finder tags”** setting
if the owner wants one suite-wide preference surface. Turning archive projection off must not leave Notes source
exports dependent on archive tags, nor accidentally suppress the notes' front matter. Notes already has partial
ownership ledgers; its Quality ownership is broader, so cleanup cannot assume all projected facets have the same
history. This part is smaller than converting the archive because Notes already separates authority and projection.

### Spotlight

There are two different requests:

- **Publish current suite fields to Spotlight.** A suite-managed search projection is the proposed route, pending platform validation. Core Spotlight can
  index app items, including a file `contentURL`; deletion can target the app's domain. It needs stable occurrence
  IDs, change/deletion handling, backfill, retry, relaunch and result-opening behavior. Treat it as a separate
  platform integration, not an already present checkbox. Apple documents
  [searchable items](https://developer.apple.com/documentation/corespotlight/cssearchableitem) and
  [domain deletion](https://developer.apple.com/documentation/corespotlight/cssearchableindex/deletesearchableitems%28withdomainidentifiers%3Acompletionhandler%3A%29).
  Deletion completion means the request was journaled, not that every result immediately vanished.
- **Make the archive unfindable in Spotlight.** Disabling the suite's projection cannot promise that. macOS can still
  index filenames, ordinary PDF OCR text, existing headers and Finder tags; a JSON companion may itself be indexed,
  depending on its type/location/importer. Apple's supported folder/disk exclusion is
  [Spotlight Search Privacy](https://support.apple.com/en-mk/guide/mac-help/mchl1bb43b84/mac). An app preference must
  explain that boundary and guide the user to that system setting. Do not rewrite OCR text, rename roots, remove
  old tags or deploy an unverified exclusion marker as a hidden side effect of “off.”

Recommended app label: **“Show archive fields in Spotlight”**, with help: “Publishes results from Archive Suite.
PDFs may also appear through macOS indexing. Use Spotlight Search Privacy to exclude an archive.” The app-owned
publisher can default off pending approval; opting out of suite publishing is not a privacy guarantee. If the
owner means absolute exclusion, ask about that scope rather than implement a misleading switch. Notes needs its
own clearly scoped publication choice too: turning archive publishing off does not erase quoted source text
already present in note files or their separately published results.

A custom importer is another route for a new companion/package type, but it would normally index that type; it does
not automatically attach JSON fields to an unrelated PDF result. Apple's archived
[importer guide](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/MDImporters/Concepts/Importers.html)
says importers cannot override an existing file type. Evaluate current extension APIs on the supported macOS
versions in a scratch feasibility test before promising PDF-result augmentation. Core Spotlight is the proposed
first experiment; no claim is made here that result deduplication, lifecycle or Privacy interaction is already
verified for this app.

| Finder mirror | Suite Spotlight publisher | What works inside the suite / externally |
|---|---|---|
| Off | Off | All Reader/Notes source fields, search and Zotero still work. Plain PDFs may remain externally searchable by macOS. |
| On | Off | Same internal behavior; Finder tags and whatever macOS indexes from them are visible outside. |
| Off | On | Same internal behavior; app-published current fields are searchable without Finder tokens. |
| On | On | Both projections; test result duplication and differing update delays, never resolve them as competing current facts. |

Switching Spotlight on over existing files queues a projection rebuild from current facts. Switching it off stops
new publishing and requests removal of that archive's app-owned entries; failure remains visible/retryable. It does
not remove the system's file index. Both settings must be harmless with offline roots, write-protected PDFs and
pending edits. A general “search off” control must not disable Reader's local full-text index as an accidental
side effect.

## 8. Existing files, migration and PDFs without a suite page 2

The no-production-output premise (owner, 2026-08-01) means **no compatibility/migration framework for disposable
suite test outputs**. Regenerate fixtures and write the chosen end-state schema. It does not mean the pre-app corpus
has no useful metadata. Its hand-applied tags and original PDFs are irreplaceable input. This analysis read no real
corpus files; all future conversion tests use scratch copies. A real-corpus write is separately owner-gated.

Under S/F/P, a PDF without page 2 can have every applicable catalogue field and correction. It needs no synthetic
text page and no Improve OCR just to change its date/title. A non-PDF supported image can use the same companion
convention under S, with no PDF identity injection. Show absent processing provenance as absent. **The old choice
“disable corrections or keep a special fallback store” is unnecessary with an external canonical store.**

Adoption of pre-existing files is an explicit import/conversion operation, not a startup side effect:

1. On scratch, inventory records without writing: readable tags, headers/XMP, old segment JSON, per-folder user
   values/date evidence, flags/rotations and container context. Report unsupported/undownloaded/unreadable inputs;
   do not force cloud content to materialize for an inventory. Determine document/page membership before mapping
   a segment's metadata onto its output files.
2. Apply one documented precedence: explicit user corrections and intentional empties win; current tag dates,
   subjects/read state/Quality remain the input for facets they own today; sidecar entity names and page-header
   item fields retain their current user > generated precedence. Sidecar dates are not allowed to overwrite a later
   Finder correction. Evidence/checks transfer only when demonstrably tied to the adopted current value. A mismatch
   is a conflict to review, not permission to guess. Preserve raw original tokens/evidence in the import report so
   ambiguous facet-like subjects are not lost.
3. Produce the new records/pairs/package or **new** embedded-PDF copies in a separate destination, with a manifest
   mapping old paths to new occurrences and links. Keep originals and any old metadata intact. Re-read every output,
   compare effective fields/text/page counts and record failures. Resume idempotently after interruption; never mark
   an input converted because only its PDF or only its metadata landed.
4. Rebuild caches and validate Reader, Notes links/source suggestions, search and Zotero on the scratch archive,
   including copied roots and duplicate filenames. A package/new-name route needs a deliberate link mapping, not a
   promise that old relative paths still work. Only a later approved real-corpus operation can apply it there.

For E, the corresponding no-page-2 choice is to add structured XMP to a **new output copy**, without inventing a
text page, or use the explicitly audited Reader writer if approved. Original PDFs may not satisfy PDF/A, may be
signed/encrypted or may not be writable. Refuse and offer an exported copy with a reason; do not offer editable
fields then silently fail to persist them. Supporting a permanent external fallback for such cases would make E
a hybrid and add the pairing/dual-vehicle cost of S; the owner should choose that knowingly.

Toggling projections is not conversion. Existing archives remain in their current storage model until deliberately
adopted; a Finder toggle cannot move years out of tags safely on its own. Once adopted, current values never change
authority when either projection setting changes. The application may recognize unadopted input, but does not need
perpetual backward-writing formats for test output that nobody keeps.

## 9. Revised question for W49.storage-one-home-owner-ok (needs you)

**Which should be the durable home of an item's current editable facts?**

- **S — a JSON companion per PDF, recommended:** Reader fields edit it; the PDF keeps transcription/processing
  history. Transfer the pair, folder or suite export to keep current facts. Accept that a PDF-only Finder move or
  copy can detach/omit metadata, and that Finder changes to mirrored tags become a deliberate import rather than
  an automatic second source of truth. New suite PDFs carry an identity; old PDFs can be associated without rewriting.
- **F — a per-folder item store:** same Reader behavior and unchanged PDF bytes; fewer files, but individual
  transfers need extracted records and moves across folders need reconciliation. Prefer this only if folder-level
  handling is the intended workflow.
- **E — structured metadata inside the PDF:** current facts follow ordinary PDF-only copies/renames/moves, without
  requiring visible editable fields on page 2. Accept the larger PDF-write/Undo/conformance refactor and explicit
  refusals/export copies for unsupported originals. This relaxes Reader's never-rewrite rule.
- **P — a document package containing PDF+JSON:** small metadata edits and one outer object to move, in exchange for
  a new document format and changed external opening/upload/attachment workflows. Plain-PDF export is still a snapshot.

The deciding test is: **must an ordinary PDF-only copy always carry the current corrected facts?** If yes, E is the
best fit among plain-PDF choices. If the owner accepts a pair/export workflow, S meets his portability requirement
with less PDF-writing risk. If keeping pairs together without PDF writes outweighs ordinary-PDF workflows, P is
worth that larger change. F remains an alternative, not a disguised solution to PDF-only sharing.

After that choice, settle the projection policy separately: recommend optional Finder mirrors (off for new archives),
optional suite Spotlight publishing (off until explicitly enabled), and separately named note projections. Confirm
whether “off in Spotlight” means no **suite-published fields**, or full folder exclusion through macOS Search Privacy.
Keeping existing tags, removing owned projections, and adopting a pre-app archive are separate deliberate operations.
These are proposed defaults, not enacted policy. Today's behavior remains until the owner answers.

This replaces the old gate's A/B/C wording and its “no page 2” sub-question. Do not execute the old
`W49.storage-drop-dead-copies` recipe by deleting the very sidecar date/evidence fields a chosen canonical route now
needs. `W49.storage-one-home`, `W49.item-fields-home`, rename/re-run and movable-root work remain behind the existing
gate and must be re-scoped to the chosen route before implementation. This analysis is complete when the question
is delivered; implementing a choice is separate work.

## 10. Size and a reviewable implementation sequence

No route is merely changing a JSON URL. Reader fields alone are **S–M**, because most controls exist. Canonical
storage/discovery is **L** under S/F; E/P are **XL** because they add a content writer or a new primary document
format. The whole implementation should be split after the decision, not assigned as one L session.

| Independently reviewable unit after approval | Relative size | Scope and reason |
|---|---|---|
| Typed effective-facts contract, evidence/check revision semantics, per-PDF/document ownership and association | M | ArchiveCore + SPEC; fixture round trips and explicit-none/conflict behavior first. A new facade can be wired before switching live storage. |
| Durable writer, identity/reassociation, local move/copy handling and pair recovery (S); folder transfer (F) | L | Reuse safe writer discipline, not name-only matching. S adds many companions; F adds cross-folder record transfer and shared-store conflict handling. |
| PDF writer and safe Undo (E), or package import/open/discovery/link support (P) | L–XL additional | Highest-risk distinguishing unit. Preserve content and account for unsupported originals; test package discovery because the walker currently skips package descendants. |
| Processor all output/finalize/retry/rebuild paths | L | Canonical-record failure must block safe source retirement; user corrections survive reruns and segmentation changes; the optional old JSON-export switch no longer controls facts. |
| Reader membership, Inspector/list/filter/search, edits/undo, flags/rotations, invalidation | L | Replace tag-based membership and absolute-path user-state storage; no blank or unreadable record silently becomes an empty answer. Root cache mobility is a separable optimization after durable user state. |
| Notes source readers + Zotero adapters + lossless subset/pair export | M | Shared API removes direct tag-date dependence; preserve containers and date roles; attachment/content and metadata export remain distinct. |
| Optional Finder projection and transitions; separate Notes projection | M + S–M | Ownership, conflicting Finder edits and removal/Undo are the work; a checkbox alone is small. |
| Optional Spotlight publisher + backfill/removal + result opening | M–L | New platform integration; prove lifecycle, duplicates and privacy boundaries on supported macOS versions. No existing suite Spotlight publisher was found. |
| Scratch adoption/conversion tool and end-to-end acceptance | L for pre-app archive tooling | Real input ambiguity and link mapping, without writing the real corpus. Disposable suite-output migration is unnecessary. Real-corpus execution remains a later owner-gated action. |

“Additional” means in addition to the shared consumer work, not in addition to doing every other vehicle. Sizes
are comparative judgement, not line counts or promised days. Actual boundaries should follow green checkpoints;
producer and consumer changes must land coherently before enabling the new route. Temporary adapters are useful
for development/input adoption; permanent two-authority operation is not the goal.

The existing root-movable wish becomes easier once user facts travel, but neither S nor a root-relative index
provides multi-root browsing or leaf-rename-proof links automatically. Likewise the unified suite-wide default
storage path remains a separate interface/location wish, not a required new master metadata database. The open
`W49.corpus-specific-audit` must not assume the old recommendation to write Finder tags/page 2 during a future
corpus migration; it should use the eventual chosen facts contract.

## 11. Evidence and verification boundary

Read-only source surveys, followed by manual checks of the surprising findings, were made against `4bffed3d`.
That first survey used source inspection only. The later scratch-PDF study starts in §12. Platform links support documented constraints, not a claim that an integration
has passed. Implementation must verify the proposed guarantees; source inspection alone cannot prove them.

Source map (repository-relative, stable symbols):

- `packages/ArchiveCore/Sources/ArchiveCore/Corpus/CorpusWalker.swift`: `tracksReadState`, `inspect`, `Options`.
- `packages/ArchiveCore/Sources/ArchiveCore/Tags/{UserItemFields,TagWrite}.swift`: `UserItemFields`, `FileIdentity`,
  `CoordinatedTagWriter`; `Containers/ContainerFileStore.swift`: locking, stamps, no-symlink writer.
- `packages/ArchiveCore/Sources/ArchiveCore/PDF/PDFHeaderCarrier.swift`: `xmpDescriptions`, `pages`; and PDF header parsing.
- `packages/ArchiveCore/Sources/ArchiveCore/Zotero/{ZoteroSidecar,ZoteroExport}.swift`: `locate`, `gather`, `issued`; `ZoteroConnector.swift` also maps `source.tags` to Zotero tags.
- `packages/ArchiveCore/Sources/ArchiveCore/Links/DurableLink.swift`: `readerReveal`; root identity in `RootMarker`.
- `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/{PDFGenerator,SegmentJSONBuilder,SearchableArchival}.swift`:
  `headerBlock`, `buildData`, `metadata`; `OCRProcessor+Tagging.swift`: `writeSegmentJSON`, `patchSidecarSentWith`,
  `entityInputs` and the item-field/date-evidence write paths.
- `ArchiveProcessor/macOS/Sources/ArchiveProcessor/Capture/LiveCaptureProcessor.swift`: `executePlans` (JSON filed
  in `JSON Output`), `filedGroupIds` and source-retirement checks.
- `ArchiveReader/macOS/Sources/ArchiveReader/Views/{TagEditorView,FieldStatusSection,NavigationModel+Zotero}.swift`:
  Inspector composition, `HeaderFields.read`, `gatherZotero`; `Search/{IndexedItemFields,ContentIndexer,SidecarStamp,
  ArchiveLibrary,FlagStore,PageTurnStore}.swift`: source merge, sidecar invalidation, path-keyed user state.
- `ArchiveNotes/macOS/Sources/ArchiveNotes/Links/{ReaderLinkResolver,SourceArchiveInfo}.swift`: `resolveExact`,
  `zoteroSource`; `Sources/RoundupYearSuggestion.swift`: `readYear`; `Core/NotesTagProjector.swift`: note-only projection.
- `SPEC/{tag-format,containers,improve-ocr,collection-settings}.md`: existing contract, corrections, exports and
  settings; these remain authoritative for current behavior until an implementation changes them together.

Future functional acceptance must cover: correction/clear/check across relaunch and rerun; a missing/malformed
record and a replaced PDF; same-volume rename, cross-folder move, root move, PDF-only copy, pair copy, duplicate
IDs and ambiguous identical content; split/merged documents; cloudy/offline/read-only roots; interrupted pair filing;
concurrent edits and Undo; Notes source dates and Zotero with all four projection settings; backfill cancellation
and projection failures; exported container context; and actual PDF bytes/images/text/conformance for S’s new identity XMP as well as E’s fact writes, with crash
recovery. Run on scratch copies only. The writer, SPEC, discovery/index, capture/finalize and concurrency changes
need Tier-2 adversarial review and functional tests; builds alone cannot establish these properties.

## 12. What a metadata edit actually did on scratch PDFs

W49.storage-metadata-review, 2026-11-21. Source baseline `709603ee`. We changed the same catalog XMP property from year 1958, revision 1, to year 1957, revision 2. Both generated fixtures had two image-and-text pages, an embedded font, a Dublin Core description, and the Suite's ordered `pageHeaders` property. The smaller file also had an ICC output intent and a PDF/A-2b declaration. The larger ordinary PDF had a rotated page, URI link, filled form, outline and text attachment. These sizes exercise different write costs. Neither represents a sample of the owner's archive.

| Writer on a new local copy | 89,395-byte PDF/A input → output bytes / median ms | 9,630,492-byte ordinary input → output bytes / median ms | What changed |
|---|---:|---:|---|
| Fixed-length packet edit | 89,395 / 0.14 | 9,630,492 / 5.96 | Two byte positions changed in an uncompressed, unique, equal-length test value. No historical revision was appended. |
| ExifTool incremental XMP | 91,963 / 114.68 | 9,632,996 / 126.60 | Original bytes remained an exact prefix, including the old year. The active catalog read the new year. qpdf reported clean structure. |
| pypdf incremental XMP | 91,974 / 1.38 | 9,633,005 / 8.91 | Same prefix and historical value. qpdf reported a missing cross-reference entry for the cross-reference stream itself on **both** outputs. Reject this candidate as tested. |
| pypdf full document save | 89,398 / 4.01 | 9,630,529 / 10.81 | Re-serialized the file. The original prefix and old JSON literal were absent. Finding no literal is insufficient to establish erasure. |

**Preservation measured.** All eight outputs reopened with the new active value. At 72 dpi, both pages' Poppler pixel hashes were identical to their own baseline, as were extracted text, decoded page-content streams, extracted images, page boxes/rotation and parsed XMP outside the two changed values. Where present, form field values, annotation subtypes, outline titles and attachment bytes matched. veraPDF explicitly validated the small baseline and all four small outputs as PDF/A-2b, five completed jobs with zero failed rules. The pypdf warning survived that green conformance result. The large fixture makes no PDF/A claim. We did not certify every reference in the object graph, every PDF/A profile, tagged accessibility structure, signature validity or third-party re-saves with these observations.

**Timing boundary.** Five staged saves of each input, same machine, median wall time, macOS 27.2.1 arm64, local filesystem. Includes reading the source and writing the candidate, plus process startup and the staging copy for the Perl CLI. Excludes independent verification, transaction journal, file coordination, durable flush, indexing, network and Undo. An append to the PDF format does not mean the library or a cloud provider wrote or transferred only the appended bytes. The fixed-size experiment materialized the whole candidate. An edited value can grow, an XMP stream can be compressed or absent, and packets can have multiple historical copies. Searching an arbitrary PDF for bytes and patching it would be unsafe. A fast save on either fixture is insufficient evidence for enabling Reader writes.

**Reproduce.** The [scratch probe](storage-evidence/metadata_probe.py) creates its own temporary directory and PDFs, accepts no archive path, and prints sizes, all five timings, prefix checks, qpdf diagnostics and veraPDF verdicts. Run `python3 ops/autonomous/heavy-run.py run -- python3 execution-plans/storage-evidence/metadata_probe.py` on a Mac with pypdf 6.7.5, ReportLab 4.4.10, Pillow 12.1.1, ExifTool 13.50, qpdf 12.3.2, Poppler 26.07.0 and veraPDF CLI 1.30.0. Inspect the per-file verdicts. PDF file IDs may vary by run. The private facts property is declared as XMP Text in a distinct test namespace with its PDF/A extension schema, alongside the existing Suite header schema. PDF/A-1/2/3 custom properties require a suitable declaration. A successful XML parse or a `pdfaid` label alone cannot establish conformance. [PDF Association extension schemas](https://pdfa.org/resource/xmp-extension-schema-templates/) · [veraPDF validation profiles and reports](https://docs.verapdf.org/cli/validation/)

