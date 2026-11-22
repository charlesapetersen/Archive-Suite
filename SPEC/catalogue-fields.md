# Catalogue field mapping and acceptance cases

[The catalogue contract](catalogue.md) defines the companion's keys, value types and identity rules.
This map applies after a root adopts that format. [The tag and PDF contract](tag-format.md) describes
the existing app paths during rollout. [The rollout plan](../execution-plans/storage-simplify.md)
covers admission, storage transactions, external projections and recovery.

## Reader Inspector, lists and search

Choose the logical document by the selected physical page's `documentID`. Resolve a split document's
owner in the same granted root instance. A file field describes the selected PDF even when its
document fields come from another PDF. For a merged PDF, a document-specific edit must identify its
target. In results spanning several documents, keep each matched fact with the document that supplied
it. A bulk file edit applies once per selected occurrence. A bulk document edit applies once per
resolved owner occurrence and document ID.

| Inspector value | Current companion location | Existing source and meaning |
|---|---|---|
| Date, including precision and Date uncertain | `fields.documentDate` | Finder Year/Month/Day or Decade plus Date Uncertain. The date and its uncertainty form one value. |
| Sent with, including its uncertainty | `fields.sentWith` | Finder Sent With and Sent With Date Uncertain. This date can be known even without an identified covering letter. |
| Publication date | `fields.publicationDate` | The printed issue date, formerly a page-2 or segment JSON item field and correctable in `item-fields.json`. It has its own precision and uncertainty. |
| Kind | `fields.documentKind` | Catalogue kind such as letter or clipping. A page reading mode such as handwritten or typed remains processing provenance. A raw classifier label is an observation. |
| Item type | `fields.itemType` | Box or Folder describes the document's archival classification. Container names and a Zotero bibliographic type are separate. |
| Title, Publication | `fields.title`, `fields.publication` | The existing page-header item fields and their corrections. Publication is the name of the periodical or other publication. |
| Byline | `fields.byline` | The published author credit as an ordered list. Preserve each name as a single string. |
| Sender, Recipient | `fields.senders`, `fields.recipients` | The names feature's entity lists and user corrections. Preserve order and literal spelling. |
| Sending place, Recipient place | `fields.sendingPlaces`, `fields.recipientPlaces` | Sending places come from entity output and its correction. Recipient places can come from item-field or entity output. Keep both roles as separate lists. |
| Subjects | `fields.subjects` | Free-form subject strings. Read the list directly. A date-like or workflow-like subject is still a subject, even if it resembles a legacy Finder control tag. |
| Read, Unread or neither | `fileFields.readState` | Finder read state today. A recorded clear means neither. Archive membership is independent of this facet. |
| Flag | `fileFields.flagged` | Local Reader flag today. A checkbox edit to false records false. |
| Colour, Quality | `fileFields.colour`, `fileFields.quality` | Finder label colour and Quality 1–3 today. Clearing either records no colour or unrated. The configured Box/Folder display tint is a preference. |
| OCR Poor, OCR Failed | `fileFields.ocrPoor`, `fileFields.ocrFailed` | OCR Poor is the user's judgement. OCR Failed records a processing outcome and does not act as the user's checkbox or as a controlled subject. |
| Rotate view | `pages[].viewRotation` | Local Reader quarter-turn override today. Record clockwise rotation relative to the selected physical page’s intrinsic orientation. Reset returns to zero. The processing rotation remains provenance. |
| Enclosed with | `documents[].enclosedWith` | Link the owning document to the covering document and its owner file. Resolve the link independently of the assessed Sent with date. |
| Repository, collection, series, box, folder, and related location/settings | Folder/root records | Use `ContainerLookup` and the existing container inspector. Show the inherited value and source, and edit at the owning level. |

Each `fields` path is relative to the resolved owning document. Lists are stored as arrays. An editor may
join values for display, but adopted consumers must derive the individual entries from the array so a
literal semicolon inside a name or place survives. Index display, field search and filters from the same
resolved fields that the Inspector uses. Derive date sort keys from the typed dates. Keep the existing
Date/Sent with role selection and tooltips. In a range query, one selected role's own value must meet
both bounds. Publication date remains its own field. The existing entry points include
`TagEditorView`, `FieldStatusSection.HeaderFields`, `IndexedItemFields` and `AdvancedSearch`.
`CorpusWalker.tracksReadState` serves legacy discovery.

Use the field's current envelope for display. Absence means unassessed. An explicit clear means the
user chose no value. Mixed is a selection state. Detached, offline, missing owner, ambiguous, invalid
and unsupported are availability states. Surface these states through the shared read result. For an
adopted root, field search, filters, Notes and exports cannot use Finder tags, PDF headers or segment JSON
to fill any of these states. Old header words may still match a PDF text search. Identify that result
as a text hit. An “unrated”, “neither”, “no date” or negative field filter needs enough information
to evaluate its predicate. A change to catalogue revision must refresh relevant displays and indexes
even when PDF bytes and timestamps are identical, including members that resolve their fields
through a changed owner.

### Editing, checks and evidence

- Commit on Return or when focus leaves the edited field. An emptied edited field records a clear.
  Leaving an untouched mixed field writes nothing. Invalid input remains visible with a hint. Flags
  use checkboxes. Display per-target failures for a partial bulk edit.
- Map the existing Checked Date, Checked Sent With, six page-header field checks and three entity
  checks to their corresponding field envelopes. A check applies only when `checkedRevision` equals
  `fieldRevision`. A value, precision, uncertainty or clear change advances the field revision.
  In existing edit flows a confirmed user value may receive a fresh check on its new revision.
  Turning date uncertainty on drops the existing check. Unchecking keeps the value. Undo and Redo
  check the expected revision before changing it.
- Keep source, route, measurement status and any available run ID, source page, region, quote and
  proposed or previous value in the relevant field's evidence. A measured model result describes
  that route and the matching reading. A later user correction carries the user's origin and any
  check of that revision. A fresh reading is a candidate until accepted. Accepting it is an explicit
  choice, including when the user previously cleared the field. Where a reading produces no value
  (for example a withheld name, a failed route or mentions alone), retain the outcome in the
  processing history. An unassessed field has no envelope to carry evidence in schema 1. Create no
  clear solely to store evidence. Preserve available attribution without inventing a page, quote or
  measured status.
- For deliberate adoption, apply the precedence in [the rollout plan's adoption section](../execution-plans/storage-simplify.md#8-existing-files-migration-and-pdfs-without-a-suite-page-2).
  Preserve the raw observations and disclose conflicts. A legacy Checked tag requires evidence that
  it describes the adopted value before it can become a revision-bound check. Legacy partial dates
  such as a month without a year or a day without a month cannot form a typed date. Retain the raw
  tokens in the adoption report and leave any unrepresentable value unresolved. Where a subset is
  valid, retain its supported precision and disclose the unresolved component. Invent no components.
- A confirmed folder-dating result may supply `documentDate` with its evidence and origin. The
  upstream folder evidence and settings belong to folder/root records. A withdrawal targets only
  its own still-current assignment. Restoring a prior date is a guarded edit that cannot override
  a later user revision.

## Processor output and history

| Output today | Treatment with an adopted companion |
|---|---|
| Page-2 Document date, Sent with and date evidence lines | Write current typed dates and associated evidence to their respective catalogue fields. A previously generated header is a dated extraction snapshot. |
| Page-2 Document kind, Title, Byline, Publication, Publication date, Recipient place | Write the accepted initial values or new candidates to the mapped document fields. Existing generated lines remain historical. |
| Names feature and tagging-call entities in optional segment JSON | Map observations to the name and place lists by role. `author_name` supplies a sender observation. Keep entity quotes and inferences identifiable as evidence. Catalogue creation and eligible entity gathering must work when optional segment export is off. |
| Original image, full OCR body or hidden searchable text | Keep in the PDF. Preserve a title, name or date when it occurs in the source transcription. |
| Actual OCR route/model, processing time, classification used for processing, source/page references and processing rotation | Keep PDF processing provenance. Preserve the text-page header for image/text pairs and the per-page provenance through searchable PDF XMP. An Inspector correction cannot change what a historic run did. |
| Page order, image/text/searchable roles and document membership | Record physical indices and page/document IDs in the companion. For a pair, use the source page ID to link the image and transcription. A grouping change goes through an explicit regrouping or processing action. |
| Segment JSON, staged requests, audit and recovery data | Keep their existing distinct purposes. Optional segment exports remain snapshots of generation. In-flight state and journals serve recovery. |

Use the typed results before `PDFGenerator.headerBlock` formats, wraps or truncates them. The legacy
`SegmentJSONBuilder` supplies entity, item-field and dating observations. A historical `enclosure_of`
basename alone does not establish a companion relationship. Keep user-directed source tag copying
independent of the catalogue's own field values.

For new companion output, omit generated headers' duplicate current fields while retaining the
transcription and actual processing provenance. This applies to both visible pair headers and the
corresponding catalogue entries in the searchable form's generated header data. The existing PDFs'
headers and XMP stay as delivered. A plain pre-app PDF can acquire applicable catalogue fields with
a confirmed association, with no synthetic text page. Improve OCR or Restore may change content
generation through its own operation. Preserve later user values, clears and still-valid checks, or
report a conflict if their document or evidence cannot be associated safely. Attribute replacement text
to the run that produced it. A preserved searchable XMP header documents the original generation.
Retain the explicit, guarded Poor OCR review action independently of that run's OCR Failed outcome.

## Notes and Zotero

Notes resolves the exact linked page within a granted Reader root and uses that page's resolved
logical document. If a file-only link names a merged PDF with multiple documents and supplies no
document selection, surface the ambiguity for single-document actions. Keep the source page link
and the physical PDF's container context. The source chip location still uses the folder store. The
roundup year suggestion uses the year of `documentDate` when every distinct source document has
the same year. Month and
day precision still provide a year, and an uncertain year remains a suggestion. A decade, an unresolved
source, or differing years yields no suggestion. Deduplicate by resolved owner occurrence and
document ID, since links to two documents in one merged PDF may disagree. The user still applies the
suggestion. Note and extract metadata, the note's own date and provenance, and Zotero references
attached to a note stay in the Notes library and are independent of the archive catalogue.

Replace legacy gathering for adopted roots at Reader's `NavigationModel.gatherZotero` and Notes'
`SourceArchiveInfo` and `RoundupYearSuggestion`. Both Zotero entry points should use one gatherer
over the resolved document fields and linked item's folder context. The table preserves the existing
type-specific payload mapping.

| Catalogue input | CSL-JSON and Connector semantics |
|---|---|
| `documentKind` and `title` | Kind selects the existing `ZoteroExport.typeMap` and Connector equivalent, and title fills title. A cleared or unassessed kind yields generic Document. A kind without a native mapping can travel in Extra. Box or Folder never chooses the bibliographic type. |
| `documentDate` | CSL `issued` at the available year/month/day precision, or a decade literal with approximate precision. Carry the date’s uncertainty in CSL and in Extra for consumers that lose the flag. Connector uses the corresponding date string and Extra. |
| `sentWith`, `publicationDate` | Keep both separately labelled in Extra, with precision and uncertainty. Neither supplies `issued` or a Notes year. |
| `byline`, `senders`, `recipients` | Use literal ordered creators. Byline provides authors where present. Otherwise an independently known sender can supply authorship. Additional senders can travel in Extra. A cleared byline remains cleared. Recipients use the native role for letters and Extra elsewhere. |
| `sendingPlaces`, `recipientPlaces`, `publication` | Report and Presentation support a sending place. Other types preserve it as Author place in Extra. Recipient places go to Extra. Publication fills the article's publication field where available and travels in Extra otherwise. |
| `subjects`, folder context, source link | CSL keywords and Extra plus actual Connector subject tags, taken from the same canonical list. Keep existing `ContainerCSL` fields/Extra for the resolved location and retain the source link independently of attaching a file. |

Use only current values for the mapped fields. A cleared or absent recipient place or publication
cannot reappear from an older entity response. Workflow flags, raw evidence and historic headers do
not supply bibliographic fields. CSL and Connector intentionally use different carriers for certain
values. Compare their meaning as well as the native payload keys. Creating a Zotero item is a snapshot.
Exporting or attaching an ordinary PDF on request uses the physical source PDF and does not transfer
its companion. Pair export and its disclosure choices are separate. Notes' Zotero-linked note
autofill reads Zotero and continues to edit only note-owned metadata.

## Acceptance cases for implementation

All cases use synthetic inputs or scratch copies. Exercise the actual entry points named below and
check the companion/field revision or consumer payload, as applicable.

| Case | Expected result |
|---|---|
| Correct a stale title and clear a recipient place | Start with a conflicting header, segment JSON and Finder tag. Reader Inspector, list, field search and both Zotero routes use the corrected title and omit the place. PDF text search may still find the original wording. New OCR provides evidence while the correction and clear persist. |
| Three dates and a check | Use uncertain `1957-05`, Sent with `1958-01-03`, and publication `1956`. Date and Sent with filters match their own roles. The intervening range cannot match by combining bounds across roles. Notes suggests 1957. CSL and Connector issue May 1957 and preserve the uncertainty. Both other dates remain labelled. Check an exact date, then turn on its uncertainty and verify the prior check expires. |
| Verbatim values through each carrier | Use international text, a semicolon inside one creator value, several ordered byline and entity entries, and a date-like subject. Match the same value and role in Reader, CSL and Connector. Switch Finder and Spotlight projections independently. Internal search and export must agree in all supported combinations. |
| Merged and split membership | Select different pages in a merged PDF and open Notes links to both. Resolve distinct titles/dates and suppress a mixed-year roundup suggestion. In a split document, edit from the non-owner and verify one owner update across a bulk selection of both members. Keep each file's flag, read state and each page's view rotation independent. |
| Notes source and note metadata | Link two distinct pages from one merged PDF, move the granted root, and add a duplicate basename elsewhere. Resolve only verified links. A stale bookmark or ambiguous root never supplies a year or Zotero facts. Reopen and Copy/Add from the source without changing note front matter or the stored link. Only applying the year suggestion edits the note date. |
| Missing association or owner | Remove the companion, supply a wrong-generation replacement, make an owner ambiguous, mark a file offline, and supply invalid and newer companions in separate subcases. Surface the reason and identify affected targets. Old observations never pass as current values. An unadopted scan can show its labelled observations. |
| Metadata-only write and refresh | On an image/text pair and a plain PDF, edit and undo a catalogue field. Compare PDF bytes before and after, then reopen Reader and Notes and rebuild the disposable index. Check that the latest committed facts and revisions travel with the pair. A PDF-only copy carries no catalogue correction. |
| Producer and rerun parity | File an image/text pair and searchable PDF via the rollout's normal output paths with segment export off and on. Verify equivalent catalogue facts and page mapping, full OCR text, and actual run provenance. Improve OCR and Restore must preserve later user edits and report unresolved mappings. |
| Unsupported Zotero roles and containers | Compare Reader and Notes CSL/Connector payloads for a letter and a report or article from the same scratch folder. Check native creators, place/publication fields, Extra fallbacks, inherited location/source link, and Connector tags. A detached or ambiguous source reports unavailable catalogue facts. Any separately requested PDF-only transfer carries just the source PDF. |
