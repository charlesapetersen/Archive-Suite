# Improve OCR — Reader flag, Processor re-read, recoverable text replacement

Design delivered by W44.reocr-plan, 2026-11-07, against `1b9e5078`. The shared contract ships in
W44.reocr-spec (2026-11-07, this commit). Implementation remains in W44.reocr-processor and
W44.reocr-reader. Both prerequisite gates are answered:
W43.sweep-owner-ok (2026-10-21) and W46.review-done (2026-11-06). No owner choice remains here.
Keep this plan until the two remaining items ship, then fold the implemented contract into SPEC and app
references and delete it. No migration: there is no app-produced production material to migrate.

## 1. Decisions and boundaries

Reader marks a person's dissatisfaction with a file's OCR. Processor owns the reader choice, cost,
execution, comparison and content replacement. Re-reading produces a private candidate first; accepting
it publishes at the original path. Rejecting a candidate leaves the original untouched. This meets the
owner's same-file intent while avoiding a provisional replacement that every open app could see.

Two premises in the October task need correcting after inspecting the code:

- Reader `Core/TagWriter.swift` delegates to Core `CoordinatedTagWriter.write` in `Tags/TagWrite.swift`.
  It coordinates metadata-only edits, verifies fresh tags and records an inverse; it has **no PDF
  replacement path**. Do not extend that metadata operation to write contents. New content writes live
  behind one Processor-only `ReOCRFileWriter`; Core shares values/parsers, not a corpus content writer.
- Reader `Search/ContentIndexer.launch` skips a file when its content mtime is unchanged. Preserving
  dates therefore requires explicit invalidation, not an ordinary rescan alone (section 7).

Reader's Core Directive, tag-write choke point and write-surface lint remain binding. This design
authorizes implementation and scratch-copy tests, never a dev/test write to the real corpus.

## 2. Flag and page header (W44.reocr-spec)

**Shared contract implemented 2026-11-07 (this commit).** Normative grammar and parser limitations:
`SPEC/tag-format.md` §Poor OCR / §2-page PDF structure. Core exposes `OCRPageKind`,
`PDFHeaderParser.parse`, `ExtractedContent.textPages` and unknown/uniform/mixed metadata summaries;
Processor writes known Kind with actual-reader provenance. Flag UI/generations and acceptance behavior
below remain requirements for the next two items. Keep this plan until they ship.

**Flag:** the Subject tag `OCR Poor`, distinct from Q1–Q3 importance and from `OCR Failed` (execution
failure). Compare by existing `tagKey`/`isSameTag`, write the canonical spelling on a new addition,
preserve an existing spelling and unrelated occurrences. Only an explicit person action sets it;
models, low confidence and failures never set it. Use existing `TagDelta`/occurrence undo through each
app's audited adapter. A checkbox/menu toggle supports one or many files, with mixed selection state;
no Set/Clear buttons beside fields. A failed read is an error, never an empty tag list.

Flagging is independent of launching Processor. Improve OCR also works on unflagged files and does
not flag them implicitly. Successful acceptance removes only `OCR Poor`; it does not remove `OCR Failed`,
Read/Unread, ratings, colour or subject/date tags. Reject/cancel/failure keeps the flag. Manual unflag
and acceptance are distinct recorded verdicts. Acceptance cannot clear a flag added again during a
re-read: a changed flag generation requires review, not a stale removal.

**Kind:** per text page, separate from segmentation `Classification`. Exact header values/IDs are
`handwritten`, `typewritten`, `printed`, `forms`; UI labels are Handwritten, Typewritten, Printed,
Form or table. Unknown is absence, never guessed `printed`. The measured classifier knows only these
four; `mixed` in an imported record does not create another class. Newspaper/register/script routing
attributes belong to the settings rules, not invented Kind values.

New text pages use this order (optional lines shown in brackets):

```text
Extracted text.
[original filename]
<Provider> · <Model> · <D Month YYYY>
[Classification: <existing segmentation value>]
[Kind: handwritten|typewritten|printed|forms]
[Document date: <existing source-date snapshot>]
[Sent with: <existing source-date snapshot>]

<OCR body>
```

One structured Core `PDFHeaderParser` parse must drive header stripping, classification, kind and
provider/model/date extraction together. Recognize the sentinel at the start of the text page, the
provenance line and ordered optional header fields; stop on the first non-header line. Do not search
body text or filenames for fields. Keep existing handling of PDFKit's dropped blank lines and wrapped
provenance. Missing, invalid, repeated or conflicting Kind yields unknown with a diagnostic; a body
that begins with a valid-looking optional header line remains an ambiguity of the existing format,
not evidence of a new classifier result. Test and document it rather than claiming perfect separation.

Provider/model are display strings, not enum lookups: retain freeform cluster names and pinned
provider/precision labels. Parse separators from the established provenance line, not arbitrary text;
malformed provenance stays unknown/raw, never an execution route. New labels use the existing
`ImportedReading.headerComponent` sanitization (one line, no middle-dot/control injection). Preserve
`makeTextPage`'s actual-reader provenance precedence, including fallback/imported readers. Stable route
IDs live in the local record; an old display label need not resolve to a current model ID.

Ordinary new Processor output writes Kind from the classifier or user's choice when known. In Improve
OCR the picker changes the private candidate immediately, re-ranks immediately, and persists only on
acceptance, preventing rejected work from rewriting an otherwise unchanged original. Preserve each
page's original filename, classification and source-date lines; update provenance and Kind only.
Expose page-level metadata in Core plus a mixed summary for interleaved files; do not apply page 2's
kind/provider to every image. Preserve existing fullBody/strippedBody consumers until explicitly updated.

## 3. Hand-off and access

Register `archiveprocessor` in Processor `Info.plist`/`project.yml` and handle open URLs in
`ArchiveProcessorApp`. Define typed request values/URL validation in Core alongside `DurableLink`.
Existing Reader citation URLs do not change.

- Small selection: `archiveprocessor://improve-ocr?request=<UUID>&root=<root UUID>&rel=<path>&rel=<path>…`.
  Construct/parse with URLComponents. Inline at most 8 files and at most 8 KiB encoded; these are our
  protocol bounds, not a claimed OS limit. Larger requests use the manifest form below.
- Large selection: `archiveprocessor://improve-ocr?request=<UUID>`. Reader atomically stages a manifest
  at `<shared support>/Requests/<UUID>.json`. Choose **common Application Support, not an app group**:
  Reader is sandboxed in Debug and Release; Processor is not. Neither has a group entitlement, and local
  self-signed identities have no Team ID. Do not remove Reader's sandbox or add group-signing machinery.
- Manifest: request ID, creation time, root UUID, root path hint, and entries containing relative PDF
  path, optional selected pair indices, expected file identity and byte digest. No keys or OCR text.
  Bounds: 1 MiB/1,000 entries; reject malformed/duplicate query keys except repeated `rel`, unsupported
  host/scheme/parameters, duplicate targets and conflicting inline/manifest forms. Require regular
  owned files in a private 0700 directory, manifests 0600, no symlink traversal. Resolve only the UUID
  under that directory, never a URL-supplied manifest path. Expire unconsumed requests after 24 hours
  with a visible “select the files again” result. Retain consumed IDs to prevent replay.

Relative paths cannot be absolute, empty or contain parent traversal. Resolve symlinks and validate
containment, root marker UUID, regular-file type and identity again when opening and committing. A
path hint is only a way to locate the folder. An incoming request **only opens the review dialog**;
it never authorizes OCR spending, flag clearing or replacement. Repeated request IDs focus the existing
job/result, never repeat a paid run. The hand-off does not implicitly use the corpus's JPEG partner.

Reader checks for the installed Processor before creating a request. If absent, keep selection/flags
and show “Install Archive Processor to improve OCR”; offer to dismiss or open an already configured
installation location, no automatic download. If launch fails, report it and retain a retryable request.

Before the first flag or re-read, the feature connects its shared support folder through the initiating
app's folder panel, with `~/Library/Application Support/ArchiveSuite/ImproveOCR` as the suggested
location (the panel may create it). The second app independently chooses/authorizes that same folder
on first connection; validate a support-store UUID so two different stores cannot silently coordinate
the same job. Persist each app's own bookmark and acquire scope for requests, receipts, acknowledgements
and flag events. This one-time connection is necessary with Reader's present sandbox, even if Processor
is not yet installed. Flagging thereafter does not launch Processor. If support access is unavailable,
refuse feature mutations with a reconnect action, never fall back to an unshared generation store.
Do not relocate an active store while jobs or unacknowledged receipts remain. A small inline request
also requires the connection for its durable flag state and completion receipts.

TCC and security scopes are per app. Neither a raw path nor Reader's scoped bookmark grants Processor
access. Processor uses its own saved grant or its own file/folder panel, verifies the selected root UUID
and paths, and balances security scopes. A denial leaves the request pending with an actionable reason.
Never call Reader `setRoot` or replace `archiveRootBookmark` for this feature. Support access and corpus
access are separate grants; the shared support folder grants no authority over an archive.

## 4. Pages, ranking and cost

Accept in-place work only on positively validated suite image/text pairs: each text page has the suite
header, each pair maps unambiguously, and the complete interleaved structure is valid. An even page
count is insufficient. Default is every image in the selected file; optional pair selections are
explicit. OCR reads only those image slots (page 1 for a two-page file), rendered into private temporary
input; never OCR the old text pages. This rendering is not the publication path.

Raw one-page/image-only multi-page originals, malformed/odd/mixed structures, encrypted/signed PDFs
and files whose preservation cannot be proved are refused for in-place improvement with the reason.
Offer the existing **separate-output** import/re-OCR route for raw originals; never route them silently
through `performMultiPagePDFReOCR`. That route renders every page to JPEG and rebuilds the PDF. Valid
interleaved multi-page files retain page count/order and replace only the selected paired text pages.

For each page show current reader, stored Kind or an explicitly provisional classifier result,
confidence/unknown, and a picker. Missing/low-confidence classification does not manufacture a Kind;
require a kind or an explicit reader choice. Mixed selections group by kind, retaining per-page overrides.
Correcting a kind recomputes the list, batch count and estimate before any run.

Use the **same ranking/resources adapter as the settings layer**, sourced by the Phase-4 rule table
and `W43.app-guide-refresh`. W44.reocr-processor therefore also waits on W46.settings-solver,
W46.settings-layers and W43.app-guide-refresh. Do not ship a parallel leaderboard using October's
unqualified guide order.
`OCRPageGuidance` is the existing seam; the replacement source/solver follows processing-review
`13-stage-rules/04-reading.md` and `10-kinds-and-routing.md`. Share route feasibility and the per-batch
stays-on-Mac constraint. Never infer capability from a display name or a custom model reusing an ID.

Rows show per-kind NES with metric (strict or answered plus fallback), n, failures, source/truth caveats,
tie status, price per 1,000 **image pages** and this selection's cost. Missing evidence is “not measured”,
not zero. A tied/higher ranked model is no promise that this particular page will improve. Mark the
current reader, even if no executable row matches it. Normal rows are executable routes only. A keyed
but unconfigured route can show its setup action disabled for Run; institutional reading is a separate
export/import action, never a one-click local execution. Imports bind to image digest and actual provenance.

Newspaper layout and other preparation rules come from the same settings plan, never a second re-OCR
pipeline policy. They affect private OCR inputs only; image pages and their existing searchable layers
stay unchanged. Reader must label the OCR-text pane as the improved transcription; image-pane embedded
copy/find can still contain the earlier reading. Updating that layer is outside this byte-preserving feature.

Run requires the person's explicit action after the estimate. Account for selected pages, route/cascade
caps, retries and already-spent cost; show unknown price rather than $0. Respect configured user ceilings.
Autonomous verification uses free fixtures and the heavy lock; any paid functional test needs the item's
cumulative estimate within the standing $7 cap. This design session spends $0 and sends no corpus data.

## 5. Byte-preserving candidate and publication

Choose a **Processor-private PDFium incremental-save adapter**, pinned and bundled with its licence,
not a Python installation or a hand-written general PDF parser. Reuse `PDFGenerator.makeTextPage`
as a text-only factory, import its replacement text pages into the original document, and save a new
private file with incremental output. PDFium exposes [incremental save](https://pdfium.googlesource.com/pdfium/+/main/public/fpdf_save.h)
and [page import](https://pdfium.googlesource.com/pdfium/+/main/public/fpdf_ppo.h). These APIs establish a
candidate implementation, **not a byte-preservation guarantee**. The first Processor checkpoint must
prove the pinned backend on scratch fixtures before UI work. No ordinary PDFKit whole-file save,
recompression or rasterized-image fallback is permitted if that proof fails.

The candidate must contain the entire old PDF byte-for-byte as its original prefix, followed by the
incremental revision. Independently inspect the **active** page/object graph: all retained image-page
content streams, encoded image/font/resource streams, annotations, inherited geometry and rotation
must reference unchanged data; only page-tree linkage needed to substitute text siblings may change.
Prefix equality alone is insufficient (a later revision can override an original object). Check exact
stream bytes and relevant object dictionaries/relationships, not merely rendered pixels. Render both
as a second check. Keep the old embedded text layer intact. Incremental history retains the old OCR
bytes too: this is recoverable editing, not redaction. Never compact it implicitly.

`ReOCRFileWriter` owns one recoverable, serialized transaction per file; multi-file acceptance reports
per-file results, never promises an all-or-nothing batch. Use NSFileCoordinator **for replacing contents**,
not TagWriter's metadata-only option ([Apple's contract](https://developer.apple.com/documentation/foundation/nsfilecoordinator/writingoptions/contentindependentmetadataonly)).
Use a same-volume sibling temporary candidate and platform atomic replacement; never truncate the live
file. Private versions/journals live at Processor Application Support `ImproveOCR/Versions/<operation UUID>/`.

1. Under coordinated read, snapshot the target identity, byte digest, root/relative path and metadata.
   Preserve a verified complete old version (data fork, xattrs/resource fork, ACL/mode, supported dates)
   durably with a prepared journal **before** any replacement. Do not rename the only original away.
2. OCR/build/compare outside the write lock. Side-by-side old/new text and kind show the candidate;
   Cancel/Reject records the verdict without changing the corpus. No successful candidate on an empty,
   refused, truncated or failed read. A partial batch cannot clear an entire file's flag; accept a file
   only when all requested pairs succeed and the person judges its transcription sufficient.
3. On Accept, coordinate replacement, re-read identity and byte digest and refuse a changed target.
   Re-read **current** tags, labels, xattrs and dates; merge no stale snapshot over intervening metadata.
   If the flag generation changed, stop for review. Stage the current metadata onto the candidate,
   synchronize and validate it. Durably journal `acceptReady` with the candidate digest, fresh metadata,
   reviewed flag generation and person's acceptance **before** atomic publication at the original path.
   Keep root marker,
   filename and all page positions unchanged; Notes' relative-path citations continue to resolve.
4. Verify the published bytes and metadata. Preserve Finder tags as a multiset, label, unrelated xattrs,
   resource fork, permissions, creation date and content modification date. Preserve other restorable
   dates supported by the volume. Inode/file-resource identity and filesystem change time can change;
   never claim otherwise. Refuse unsupported metadata preservation rather than quietly losing it.
5. Durably mark `published` and write the content-revision receipt immediately after verification,
   independently of flag clearing. Then clear only the reviewed `OCR Poor` generation via the existing
   coordinated tag primitive, under section 6's generation lock/check. Journal `flagCleared` and the
   accepted verdict; later flag-status receipts supplement the content receipt. Tag
   clearing and PDF replacement are **not one atomic filesystem operation**. If flag clearing fails,
   retain the good PDF and backup, show “text accepted; flag still needs clearing”, and retry that step
   only. Never re-run OCR to repair a tag failure or report the transaction complete prematurely.

Fsync/synchronize candidate, backup, journal and containing directories at durable boundaries. Failure
before publish leaves the old file live; failure after publish leaves a verified recoverable old version.
Startup recovery compares journal state and before/after digests before proceeding: `acceptReady` with
old live bytes means not published, return to review without automatic replacement; candidate bytes
mean finish verification and reconstruct the content receipt even if clearing the flag is conflicted.
Anything else is a conflict. Do not guess, delete the backup, re-run a paid call or overwrite a later
editor's work.
Exercise interrupted atomic replacement and metadata failures, not only process crashes while OCR runs.

Keep accepted versions until the user explicitly removes them in Processor's history UI; no automatic
expiry of the last recoverable original. Show retained size and refuse new work if space is insufficient.
Undo/Restore is another guarded transaction, with its own backup and receipt, available across relaunch.
Restore old PDF bytes only if the live digest matches the recorded accepted revision; preserve current
unrelated tag edits and re-flag only when the original was flagged and no later manual flag action
conflicts. Otherwise ask within the feature's review UI. Reader's pre-replacement tag undo must retain
its existing inode/identity refusal; never bypass it to target a new file object.

## 6. Local evidence, not automatic benchmark truth

The shared support store owns per-file flag generations, keyed by root UUID and normalized relative
path, plus durable intent/terminal event files. Each explicit suite flag/unflag action advances a UUID
generation, even if the requested boolean already matches. All suite tag edits that affect `OCR Poor`,
including generic subject edits and undo, must pass this adapter; unrelated tag edits retain the existing
writer. A cross-process advisory file lock per target serializes these operations and acceptance.
Lock order is always flag-store lock, then NSFileCoordinator; never acquire that lock from a coordinator
callback or nest a second coordinator. Write/sync intent with next generation and desired boolean,
perform the delta through the audited tag primitive, then commit the generation/event. A crash leaves
the intent as a generation barrier: reconcile the actual tag before admitting another operation, and
never let an older acceptance clear across that barrier.

Acceptance checks the reviewed generation while holding this lock at publication; its later flag-clear
operation reacquires the lock and compares again **inside that serialized operation**. A mismatch leaves
the flag for review. Restores use the same protocol. This guarantee covers cooperating suite actions.
Finder or another tool can perform a present→absent→present cycle without an event; a boolean tag alone
cannot reveal that ABA. Re-read actual tags inside coordination, preserve unexpected changes and state
this external-writer limit; do not claim generations detect arbitrary outside edits.

Use operation UUIDs and durable intent/terminal events. Reader extends its existing audit ledger for
flag/unflag: root UUID + relative path, time, operation, before/after flag generation, reader/kind when
known and unknown explicitly. Persist intent before the tag delta; recovery reconciles interrupted
events with the actual tag. Failure to finish the audit is visible, never silently reported as success.
Processor's journal records request/pair IDs, source/candidate digests, old/new reader display and route
IDs, kind before/after and origin (header/classifier/person), settings/guidance revision, estimate/actual
cost, errors, accepted/rejected/cancelled/restored verdict and version references. Unknown old provenance
is valid. Only atomic event files or a transactional store, never unprotected JSON read-modify-write.

These records and versions are local/private; hand-off receipts carry no OCR text or credentials. No
background upload or automatic addition to benchmark truth: a person's “poor” flag is a selected
difficulty signal, and acceptance is preference, not a transcription adjudication. A later bench must
separately obtain/prepare scratch inputs, provenance and truth. Reuse the kit's review record identity
where available; do not make W44 depend on training or add a second truth store.

## 7. Reader completion, even while closed

Processor writes durable revision receipts at `<shared support>/Receipts/<operation UUID>.json`:
root UUID, relative path, selected pairs, before/after digest, operation/revision and outcome. A wake-up
notification is only a hint, with no arbitrary path/access authority. Reader validates receipts against
its own granted root and the current bytes. Keep them until acknowledged by Reader; acknowledgements
are idempotent and never delete Processor's recovery journal. Handle out-of-order chains and stale
receipts by re-reading the current target, not loading a saved version over it.

On notification, launch and root activation, consume pending receipts and invalidate the affected
ContentIndex row **regardless of mtime**, re-extract text, refresh metadata/thumbnail caches, and advance
a content revision only after success. A crash before acknowledgement retries safely. Also strengthen
ordinary rescan's index freshness key with replacement identity/size/change metadata so an external
replacement or a missing receipt cannot preserve stale FTS solely because mtime was restored.

`DocumentViewerModel.loadCurrent` must recreate the PDFDocument and extracted text for the revision;
include it in `pageIdentity`/pane identity, clear stale find/selection state and retain zoom/current pair
where valid. Closed document windows reopen normally. Test Reader closed during acceptance, PDF open
during acceptance, rejection, restore and a changed-mtime-free replacement; old/new text search must
give the correct results. Page 1's pre-existing text layer remains searchable as section 4 explains.

## 8. Implementation sequence and proof

| item | deliverable and gate |
|---|---|
| W44.reocr-spec | SPEC flag/header decisions; structured per-page Core header values and tests; new-output Kind/provenance round trips in both apps. No content writer in Core. |
| W44.reocr-processor | Wait for spec, W46.settings-solver, W46.settings-layers and W43.app-guide-refresh. First pin/prove incremental writer and backup/recovery; then hand-off decoder/access and shared solver adapter; finally dialog, candidate review, guarded acceptance/restore, records and receipts. Checkpoint at each verified unit. |
| W44.reocr-reader | Wait for Processor. Flag/unflag/filter in row/document/menu commands and a nonconflicting keyboard shortcut; provider/Kind display; request creation; receipt/index/document refresh; off-screen interaction proof. |

Keep schema/URL/receipt value types in Core; app-owned transport stores and content writes stay in their
audited adapters. Any new Reader app-support write needs a precise audited lint allowance, never a
blanket exception for corpus contents. Later SPEC implementation makes the contract normative; this
plan does not change SPEC or ship a writer today.

Each implementation is Tier-2: a separate adversarial review plus a functional test on scratch copies,
no real corpus, no bare-build signoff. Build/test the apps touched and Core as applicable, run Reader's
write-surface lint for every Core change, use the heavy lock, and run launching tests outside the sandbox.
The acceptance matrix must include:

- Two-page and several-pair PDFs, selected pairs and several kinds/readers; no OCR of text slots; raw,
  odd, encrypted, signed, corrupt and misleading header-like inputs refused without source writes.
- Header-less/missing/unknown/wrapped provenance; Kind conflicts and body/filename traps; full-body
  search and stripped display; actual fallback reader named; no fabricated model IDs or measurements.
- Exact original prefix **and active image object graph/stream preservation**, geometry and raster
  equality; untouched text pairs and existing image text layer; original path/root/page citations.
- Duplicate/case-variant tags, label, date roles, xattrs/resource fork and permissions; concurrent
  metadata edit retained, content/identity/symlink/root change refused; repeated flag action not cleared.
- Fault injection before/after backup sync, candidate write, publish, verification, flag clearing,
  receipt and acknowledgement; disk-full/access-denied; restart and restore with later edits. Assert
  the live file is a complete old/new PDF and a recoverable original always exists after publication.
- Malformed/oversize/replayed hand-offs, unavailable Processor, denied scope and stale requests; no
  execution on URL receipt, no access escalation and no Reader root/settings mutation.
- Kind change re-ranks via the shared solver; infeasible routes excluded, ties/caveats/missing price
  honest, corrected batch estimate and ceiling enforced, failed pages never accepted as blank output.
- Headless Reader render guards plus off-screen VM flag/filter/hand-off/accept/restore interactions;
  inspect captured pixels. Explicitly test FTS and an open document refreshing with the **same mtime**.

Design validation: read-only code surveys of both apps and Core at the baseline above, plus a separate
adversarial pass over this plan and tracker/dependency checks. No app build, GUI run, PDF mutation,
paid run or preservation proof is claimed by this documentation item. The writer proof belongs to the
first W44.reocr-processor checkpoint and must stop publication if it cannot meet these invariants.
