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
`CatalogueAssociation.pair` accepts positive evidence obtained independently from the candidate
JSON, scoped to the exact occurrence. It verifies the file ID, content generation and physical page
count. A name, size, timestamp, PDF trailer ID or byte digest alone is insufficient. A companion
must never be applied to a replacement at the same path on name evidence, even after a restart.
A metadata edit changes `revision` and records its direct parent revision IDs. A content replacement
also advances `contentRevision`. Writers and proof acquisition are later stages.

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
(round-tripped as written) can be introduced without changing required semantics. Common page roles
are `image`, `text` and `searchable`. Common origins are `user`, `model` and `imported`. Unknown
roles or origins confer no edit privileges. Use `read` and `unread` for read state, `box` and `folder`
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
unknown data at any depth. Its typed view is for reading. A future editor must patch a lossless
representation and revalidate it, or refuse the operation if it cannot safely preserve unfamiliar data.
Record decoding is pure. The shared reader below supplies read-only file access.

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
