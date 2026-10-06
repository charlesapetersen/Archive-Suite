# Archive Suite — Tag & PDF Contract (`SPEC/tag-format.md`)

## Purpose & status

**This file is the single source of truth for the Finder-tag vocabulary and 2-page PDF format
that Archive Processor _writes_ and Archive Reader _reads and edits_.** It is the only real
coupling between the two apps, and it governs **irreplaceable, expensively-tagged archival data**:
a silent divergence between writer and reader would corrupt tags or mis-read documents that cannot
be re-created.

**Both apps MUST interpret every rule below identically.** When the two disagree, this spec plus
the cited source files are authoritative — not prose in either README. Any change here is a
coordinated, two-app change (see *Divergence risk & change protocol*).

Cited from `ArchiveProcessor/CLAUDE.md` (§Tagging, §OCR Output Format) and
`ArchiveReader/CLAUDE.md` (§Verified Facts, §Safety Protocol). Line references below are current as
of 2026-07-06; treat the surrounding function, not the exact line, as the anchor.

Status: **settled / non-negotiable.** Reflects Processor + Reader source as merged into the
Archive-Suite monorepo.

---

## Finder tag model

Tags are **macOS Finder tags** — file extended-attribute metadata, not file content.

| Operation | API | Source |
|---|---|---|
| Read tag names | `url.resourceValues(forKeys: [.tagNamesKey]).tagNames` → `[String]` | `MacOSTagger.readTags`, `TagWriter.mutate` |
| Write tag names | `(url as NSURL).setResourceValue([String], forKey: .tagNamesKey)` | `MacOSTagger.applyTags`, `TagWriter.mutate` |
| Read/write color label | `.labelNumberKey` (Int) | both (`finderLabelIndex` / `ArchiveColor`) |
| Discover tagged files | walk the granted root; read `.tagNamesKey` per file | Reader `ArchiveCore.CorpusWalker` (+ `ArchiveLibrary` cache) |

- The tag array is an **ordered `[String]`**; macOS may reorder on write, so consumers compare as a
  **multiset**, never by position.
- **Duplicate tag strings persist verbatim.** A `.tagNamesKey` write→read round-trip preserves repeated
  strings: `["A","A","B"]` reads back as a two-of-`A` multiset, **not** the collapsed `["A","B"]` — macOS
  does not de-duplicate the tag array on write. *(Verified on macOS/APFS by
  `ArchiveCoreTests/DuplicateTagPremiseTests` — a hard-asserted pin, complemented by the
  `XCTSkipUnless`-guarded occurrence-aware consumer tests.)* This is **why** consumers compare as a multiset
  (above) and why occurrence-aware undo/restore must carry per-token **multiplicity** (ArchiveCore
  `tagOccurrenceInverse`, Wave 15) — a `Set`-collapse would silently drop a duplicate on undo.
- **Color-name-token preserves labelNumber.** The color label (`.labelNumberKey`) and a color-name
  token (`"Red"`/`"Purple"`) in the tag array are two representations of the same fact. **Verified:**
  keeping the color-name token in the array and writing only `.tagNamesKey` **preserves the existing
  `labelNumber`** without writing it. Processor still writes `.labelNumberKey` explicitly
  (`MacOSTagger.applyTags`, lines 72–76: set to 6/3, or `0` when no color); Reader writes it **only**
  when a delta changes color (`TagWriter` §7), otherwise restores drift.
- **No search index is ever tag truth.** The filesystem xattr read through `.tagNamesKey` is the only
  authority. Spotlight's `kMDItemUserTags` was the Reader's discovery mechanism until `W26.walk2` replaced
  it with a direct walk (`ArchiveCore.CorpusWalker`) plus a disposable `LibraryIndex` cache and FSEvents;
  it is lossy and stale, and the same rule binds the cache that replaced it. Never build a write array
  from a cache or an index — only from a fresh per-file read (Reader `TagWriter`/CLAUDE §Safety-5).

---

## Tag facets

A file's tag array intermixes the facets below. Classification into facets is **display / sort /
filter only** and **must never drive a destructive write** — subjects can collide with any facet
token (a subject literally `1984`, `P7`, `Read`, `Box`), so a mis-classified facet is acceptable
(the user corrects it in the UI) but a facet-driven token removal is not. Reader's canonical parser
is `DocumentTags.parse` (`Core/DocumentTags.swift`); Processor emits them from `GeneratedTags.allTags`
(`Tagging/TagGenerator.swift`).

Parse order matters (read-state / quality — incl. the legacy `P7`–`P10` priority alias — / month / day are
recognized **before** the bare-number year test, so `Q2`, `P7`, or `Day 25` is never taken for a year).

| Facet | Exact string form | Cardinality | Notes |
|---|---|---|---|
| **Year** | bare digits, e.g. `1980` | 0–1 | Processor's LLM prompt forces a **4-digit** year and never null for a dated doc. Reader's `parseYear` accepts **3–4 digits** (medieval-friendly: `800`, `1215`). See discrepancy #1. |
| **Month** | `MM Month`, e.g. `03 March` | 0–1 | `MM` = 1–12, name must match that month (case-insensitive). Processor applies `capitalizeFirstLetters`, so it is emitted title-cased. Month is written **only when explicit in the doc**, never inferred. |
| **Day** | `Day N` (unpadded), e.g. `Day 25`, `Day 1` | 0–1 | N = 1–31. Often absent. |
| **Decade** | `NNNNs`, e.g. `1970s` (a 3–4 digit run whose **last digit is `0`**, then a **lowercase** `s`; medieval-friendly `970s`) | 0–1 | An **approximate** date spanning ten years. **Mutually exclusive with Year** — a concrete Year supersedes a Decade. Recognized alongside the bare-number Year test (the trailing `s` means it can never match the digits-only Year test, so order is immaterial). Written by the Processor **only** when the user types it into the manual tag dialog's Year field; the LLM tagger never emits it. Reader parser: `DocumentTags.parseDecade`. |
| **Date Uncertain** | literal `Date Uncertain` | 0–1 | Flags a **speculative year** — the file _usually still carries a Year tag_. Not "no date." |
| **Quality** *(the rating facet)* | exactly one of `Q1` `Q2` `Q3` (higher = better) | 0–1 | **The single importance/quality rating (W19, 2026-07-18) — MERGED with + supersedes the legacy Priority facet** (`Q3` = old `P10`). A human 0–3 rating; **`Q0`/unrated writes NO tag** (absence *is* 0 stars, so the wire only ever carries `Q1`/`Q2`/`Q3`). Human-set everywhere, **never LLM-emitted**: Notes (front-matter `quality`), Reader (edit), Processor's interactive tagging (Live Capture tag card + Process Files manual tagging), and the **phone companions** (per-page/segment — the old priority control now emits `Q`). Q-prefix can never collide with the digits-only Year test. |
| **Priority** *(legacy → Quality)* | `P7`–`P10`, on pre-W19 files only | 0–1 | **RETIRED — merged into Quality (W19, 2026-07-18).** No longer written by any app or companion. **Read-only alias:** `P8`/`P9`/`P10` parse as `Q1`/`Q2`/`Q3` and `P7` as unrated, so pre-W19 phone-captured files still resolve without a corpus rewrite. |
| **Read state** | `Read` or `Unread` | 0–1 | Matched **exact whole-string, case-insensitive**. Processor stamps `Unread` **last** on new real-tagging output. |
| **Subject** | free-ish strings, title-cased | ~2–6 | Everything not claimed above, kept **verbatim**. Processor caps the LLM at 6 (`TagGenerator.parseTagResponse`). Box/folder pages carry the literal subjects `Box`/`Folder`. OCR failures carry `OCR Failed`. |
| **Color label** | `.labelNumberKey` + color-name token | 0–1 | **Red = 6 ⇒ box** photo; **Purple = 3 ⇒ folder** photo. Only these two are meaningful to the Suite. |

**Subject-collision rule (critical).** Facet detection is heuristic and lossy-by-design; the raw
array is the source of truth. A subject that happens to equal a facet token must survive: e.g. a
document about the "Red Scare" with **no** red label keeps `Red` as a subject (Processor
`MacOSTagger.applyTags` `colorIsAuthoritative` path; Reader `DocumentTags.parse` color check gated on
the file's actual `labelNumber`).

---

## Chronological sort key

Derived from Year/Month/Day into one sortable integer (Reader `DocumentTags.sortDate`):

```
sortDate = year * 10_000 + (month ?? 0) * 100 + (day ?? 0)     // nil when no year (and no decade)
// A Decade tag with no Year sorts as the decade's first year, Jan 1:
// sortDate = decadeStart * 10_000   (e.g. "1970s" → 19_700_000)
// so it interleaves with dated files exactly where a year-only "1970" doc sorts.
// If a concrete Year is also present it takes precedence (Year supersedes Decade).
// The Date column displays the verbatim decade token ("1970s"), never a synthesized
// concrete date, and renders it italic (speculative), like Date Uncertain.
```

- **No epoch limit** (unlike the deferred creation-date mirroring, which is ~1678–2262). Medieval and
  ancient years sort correctly.
- Year-only sorts just before its January (month/day count as 0).
- **Date-Uncertain files sort by their speculative year like any dated file** — they are **never
  dumped to the end.** The nav window renders their derived date in **italics**
  (`dateIsSpeculative`) to signal speculation.
- Undated rows (`sortDate == nil`) sort to the end.
- BC dates are **not currently representable** — the year token is unsigned digits; true BC support
  would need a negative-year token this format does not yet define.

---

## 2-page PDF structure

Processor emits **one PDF per input image**, same base filename (`PDFGenerator`).

- **Page 1** — the original photographed image, correctly oriented. In the test corpus it carries
  **no** text layer; **in production the image page will often also carry a searchable text layer**,
  so a consumer's copy/find must work on whichever pane holds the selection.
- **Page 2** — the OCR text as **real selectable text**, on a single dynamically-tall page (no
  overflow to page 3).

> **Interleaved multi-page variant.** A single output PDF may **alternate image, OCR-text, image,
> OCR-text, …** — each source page contributing its image page followed by its page-2-format OCR-text
> page. This is produced by merged multi-page documents (`PDFGenerator.mergeDocumentPDFs`) and by the
> Processor's **"Re-OCR multi-page PDF"** mode (renders each page of an input PDF, re-OCRs the page
> image, and rebuilds one interleaved PDF). It is **not** a format break: every (image, text) pair
> follows the page-1/page-2 contract above, and the "consumers must not hard-assume 2 pages" clause
> below already covers it. Consumers read OCR text off **every** text page, not just page 2.

**Page-2 header** (built by `PDFGenerator.makeTextPage`, lines 212–224; parsed by both
Processor `OCR/PDFTextExtractor.swift` and Reader `Search/PDFTextExtractor.swift`):

```
Extracted text.
<original filename>            ← verbatim source name, ANY image ext (.jpg/.png/.tiff/.heic); may be ABSENT
<Provider> · <Model> · <D Month YYYY>   ← separator is U+00B7 with surrounding spaces; date e.g. "9 March 2026"
Classification: <value>        ← OPTIONAL line; absent on older/heuristic/Mistral/hand-added files
                               ← blank line
<body text…>                   ← or "No text returned by model." (+ error) on OCR failure
```

- `<Provider>` is `model.provider.rawValue` (`Anthropic`/`Google Gemini`/`Mistral`/`OpenAI`/`Apple Vision`),
  a custom gateway display name, **or** `Local CLI Agent (<tool>)` for a subscription-authenticated CLI —
  treat as free-form. A Local Agent's model position is its explicit CLI override or `CLI default`, never
  the selected direct-provider fallback. For example, the on-device backend writes
  `Apple Vision · macOS Vision` in the header's provider/model positions.
- **Classification — verified values (exact strings):** `Document Start`, `Continuation`, `Box`,
  `Folder`. (These are `DocumentClassification.displayName`; the enum's Codable rawValues
  `document_start`/`document_continuation`/`box_label`/`folder_label` appear only in JSON sidecars,
  **never** in the PDF text.)
- **Classification may be ABSENT.** It is written only when the Processor knows it; consumers **must
  degrade gracefully** (fall back to filename-sequence order + manual grouping). Never build a core
  behavior that assumes it exists.
- **Reading segments = document units.** A _document_ (a `Document Start` + following `Continuation`
  pages) is finer than the Red/Purple box/folder markers. The Classification lives in page-2 **text**,
  so it is read via the content index, not a tag.

**Consumers must not hard-assume 2 pages.** Guard against 1-page, >2-page, 0-page,
corrupt/encrypted, and tagged **non-PDF** images (box/folder markers may be plain images). Degrade,
never crash (Reader `PDFTextExtractor`, `PDFPaneView`).

---

## Invariants both apps must honor

1. **Reader's Prime Directive.** Reader MUST NOT delete, move, rename, trash, re-save, or alter any
   file's **bytes or location** — ever. Finder-tag metadata (the tag-name array + the color label) is
   the **only** thing it changes, and only via one audited choke-point, `Core/TagWriter.swift`.
2. **Single write choke-point.** Every Reader tag write (subject/date/priority/color, group edits,
   Read/Unread triage) routes through `TagWriter.apply` as a **delta** `{add, remove, color}` against
   a **freshly-read** array, then verifies by re-read (multiset equality + label + data-fork-hash
   unchanged). Coordinated with `NSFileCoordinator(.contentIndependentMetadataOnly)`, never
   `.forReplacing`.
3. **Trustworthy-read guard (prevents the catastrophic tag-wipe).** If a tag read throws or returns
   `nil` tagNames, **ABORT** — a read failure is **never** coerced to `[]`. A confirmed-empty array
   and an unreadable file are distinct (`TagReading`, `TagWriter.mutate` §3). Processor's
   `MacOSTagger.readTags` likewise returns `[]` only on a genuine read, and its copy-source path
   writes nothing when the source array is empty.
4. **Exact whole-string, case-insensitive token matching.** Never substring — removing `Unread`
   never touches a subject `"Read later"`; Read/Unread compare case-insensitively, all other tokens
   exactly (`TagWriter.shouldRemove`/`isSameTag`; `DocumentTags.parse`).
5. **Lossless writes.** `new = (fresh − remove) + add`, every untouched token preserved verbatim; a
   no-op delta writes nothing (no mod-date churn). **Never** build the write array from any index or
   cache — not Spotlight's `kMDItemUserTags` (the Reader's discovery mechanism until `W26.walk2`), and
   not the `LibraryIndex` rows that replaced it. Only a fresh per-file `.tagNamesKey` read.
6. **`Unread` stamped last, once.** In real-tagging modes only (`.automatic`/`.autoDate`/
   `.autoDateManualSeg`/`.human`), Processor drops any incoming `Unread`, writes all other tags,
   then appends exactly one `Unread` as the final element (`MacOSTagger.applyTags`, lines 42–66).
   "No tagging" and "Copy source tags" modes stamp nothing and pass source tags through verbatim.
7. **App-authoritative color.** In real-tagging modes Processor assigns exactly one of Red(box)/
   Purple(folder) and writes `.labelNumberKey` accordingly (or `0` to clear a stale swatch). A
   subject string equal to `"Red"`/`"Purple"` is **never** promoted to a color label
   (`colorIsAuthoritative` path). Reader writes `.labelNumberKey` only when a delta changes color.

---

## Where each side lives

| Facet / element | Processor (writer) | Reader (reader / editor) |
|---|---|---|
| Tag read/write primitives | `ArchiveProcessor/.../Tagging/MacOSTagger.swift` | `ArchiveReader/.../Core/TagWriter.swift`, `Core/TagReading.swift` |
| Year / Month / Day / Date Uncertain | `Tagging/TagGenerator.swift` (`GeneratedTags`, prompt) | `Core/DocumentTags.swift` (`parseYear`/`parseMonth`/`parseDay`) |
| Decade `NNNNs` | `Views/ManualTaggingSheet.swift` + `Views/ManualSegmentTagView.swift` (Year date field → verbatim via `GeneratedTags.allTags`/`MacOSTagger`) | `Core/DocumentTags.swift` (`parseDecade`/`sortDate`/`displayDate`) |
| **Quality `Q1`–`Q3`** (the rating facet; supersedes Priority, W19) | user-set in the Live Capture tag card (`Views/LiveCaptureView.swift`) + Process Files manual tagging (`Views/ManualTaggingSheet.swift`, `ManualSegmentTagView.swift`) via `GeneratedTags`/`MacOSTagger`; **companions emit `Q`** (`net/MacClient` ↔ `Net/CaptureServer` route — SHARED HOTSPOT, change all sides together); never LLM-emitted | `Core/DocumentTags.swift` (`parseQuality`, shared; **legacy `P8`–`P10`→`Q1`–`Q3` alias on read**) + `Core/TagWriter.swift` (set/clear). **Also set by Notes** (`NotesTagProjector` ← front-matter `quality`). |
| **Notes date facets** (Year/Month/Day/Decade) | (n/a) | **Deferred — W19.date.** Notes currently keeps front-matter `date`+`datePrecision` authoritative; the queued projector work will reuse the existing date facets and `ArchiveCore.DocumentTags.sortDateKey` (no new vocabulary). |
| Read/Unread + `Unread`-last | `Tagging/MacOSTagger.swift` (`stampUnread`) | `Core/DocumentTags.swift` (`ReadState`), `Core/TagWriter.swift` (`setReadState`) |
| Subjects | `Tagging/TagGenerator.swift` | `Core/DocumentTags.swift` (`subjects`) |
| Color label (Red=6/Purple=3) | `Tagging/MacOSTagger.swift` (`finderLabelIndex`) | `Core/DocumentTags.swift` (`ArchiveColor`), `Core/TagWriter.swift` |
| Chronological sort key | (n/a — Reader-derived) | `Core/DocumentTags.swift` (`sortDate`) |
| 2-page PDF + page-2 header | `OCR/PDFGenerator.swift` (`makeTextPage`) | **Shared:** `ArchiveCore` `PDFHeaderParser` (extract, `fullBody`/`strippedBody` split, `parseClassification`). Reader indexes `fullBody`; Processor shim uses `strippedBody`. `PDFFormatStatus` also in Core. |
| Classification enum / values | `Models/ProviderModels.swift` (`DocumentClassification`), `OCR/PDFTextExtractor.swift` (shim maps string→enum) | `ArchiveCore` `PDFHeaderParser` returns raw `String?`; `Core/DocumentRuns.swift`, `Search/ContentIndex.swift` |

---

## Divergence risk & change protocol

The shared contract is the single biggest risk in the Suite. Therefore:

- **Any change to this contract is a coordinated, atomic three-way change:** Processor's writer +
  Reader's parser/writer + **this spec**, in the same coherent batch. Never land one side alone.
- **Persisted enum stability:** `DocumentClassification` and `TaggingMode` rawValue strings are
  persisted (UserDefaults / JSON snapshots). Never rename a case or change an explicit rawValue —
  appending cases is safe.
- **Treat as Tier-2 (adversarial review + tests on scratch copies).** Both apps class tag/PDF write
  code as high-blast-radius: multi-agent adversarial review plus targeted tests. **Never test tag
  writes against the real corpus — always a scratch copy.**
- **Shared write primitive (DONE).** Both apps now write tags through
  `ArchiveCore.CoordinatedTagWriter.write` — a single audited choke-point with coordinated access,
  trustworthy-read guard, verify-by-re-read, and inverse-delta derivation. Processor's `MacOSTagger`
  and Reader's `TagWriter` are thin adapters that translate app-specific semantics (fresh-write vs
  delta-apply) into transform closures over the shared primitive. This spec is that package's contract.


---

## W37.dual-date — enclosure dates (proposal, 2026-10-05)

**DESIGN ONLY; pending the owner's behaviour choices.** The contract above still describes the
implemented single-date format. None of the tokens or behaviour below is implemented or normative yet.
Baseline: `3465e15`. The owner already required two dates for an enclosure with its own date; the open
question is how those dates behave in the apps, not whether to add the feature.

### Recommended behaviour

| Concern | Proposal | Alternative for the owner |
|---|---|---|
| Sort | The item's own date sorts; when it is absent, use the sent-with date as a visibly labelled fallback. | Sort by the covering letter's date whenever present. |
| Filter | A date filter matches either complete date value, returns the file/note once, and shows which role matched. | Match only the date used for sorting. |
| Enclosure identification | Automatic segmentation may propose a relation; a manual control can confirm, correct, or remove it. Ambiguous relations go to review. | Require a manual relation for every enclosure. |

Example: a report dated 1957-11-03 sent with a letter dated 1958-03-12 sorts at **1957-11-03**;
filters for either date find it once. The table/inspector shows **Date: 3 November 1957; Sent with:
12 March 1958**. It does not imply the report was written in 1958. A covering letter keeps its own
1958 date; it does not acquire the report's 1957 date. Equal dates remain separately labelled, with
one list row. Missing dates stay missing; uncertainty belongs to each role separately.

Use the existing Notes sort-key range semantics for each value; never pair the item's year with the
covering letter's month/day. Lower and upper bounds must both be satisfied by the SAME value:
an item dated 1950 and sent in 1970 must not match a 1960–1965 range. Year-only and decade values
retain their existing sort-key behaviour; this feature does not silently replace it with interval overlap.

### Proposed wire and display

Keep the existing Year/Month/Day/Decade/Date Uncertain family as the **item date**. Add one labelled
whole-value token for the covering letter's date, so precision and role cannot cross-pair:

| Token | Cardinality | Meaning |
|---|---|---|
| `Sent With 1958`, `Sent With 1958-03`, `Sent With 1958-03-12`, or `Sent With 1950s` | 0–1 total | Covering letter date, with year/month/day/decade precision respectively. |
| `Sent With Date Uncertain` | 0–1 | Speculative sent-with date; independent of `Date Uncertain`. |

Proposal grammar: exact title-cased prefix `Sent With `; 3–4 ASCII year digits (same supported width
as the existing Year facet), zero-padded month/day, or a decade ending in `0s`. Validate components
without inventing missing precision. Invalid or conflicting tokens remain verbatim and surface as
ambiguous metadata; they must not silently produce a synthetic combined date or trigger a cleanup write.
A role-looking subject is still a subject-collision risk: facet parsing must never authorize deletion.
Date edits use explicit exact-token deltas against a fresh read, preserving untouched tokens and
multiplicity through the existing audited writers. Notes projection retains its exact ownership ledger.

For newly generated PDFs, add optional **Document date:** and **Sent with:** lines to the OCR-text
header, before its separating blank line, repeating the document-unit pair on that unit's text pages.
These are source-document dates, distinct from the provider/model line's **OCR processing date**.
Both shared-header body stripping and classification extraction must recognize the new lines together;
Reader keeps its existing full-header search behaviour. Reader edits remain metadata-only: they must
never rewrite existing PDF bytes. The PDF header is an output-time snapshot; the Reader's live display
uses fresh Finder tags. An owner correction can therefore differ from that snapshot.

### Extraction and Notes

The owner already approved independent document units for enclosures with their own date/author/heading
(`execution-plans/segmentation/02-truth-check.md` §Document rules); an undated/unheaded attachment stays
part of the letter. Preserve that decision. New merged outputs follow those units; an existing input PDF
combining independently dated units needs review/resegmentation, not an arbitrary choice of a single own date.

A document-unit relation, not mere adjacency or a date mentioned in body text, identifies an enclosure.
Carry the covering unit's identifier and independently extracted date through segmentation, review,
tag generation and finalize. Allow multiple enclosures to reference one letter; never carry a relation
across an unconfirmed boundary. The manual tag sheet exposes both labelled values and the relation.
If either date/relation is missing or disputed, retain the known value and ask for review rather than
borrowing the nearest date. The segmentation experiment is not itself a production relation detector.

Notes keeps its primary `date`/`date_precision`/`date_uncertain` as the item's own date and adds structured
`additional_dates` entries with role, date, precision and uncertainty; at most one `sent_with` entry.
Reuse the primary-plus-additional model idea from `execution-plans/devonthink-import.md` §3a, while
leaving the DEVONthink import ON HOLD and its retained plan untouched. Other additional date roles may
use that model later; W37 needs only `sent_with`. List/search snapshots stay one row per UUID; store
role-labelled dates separately in the disposable index and match either role without duplicate rows.
Project only the item's own Markdown file through `NotesTagProjector`; linked corpus PDFs stay read-only.
No migration is planned because there is no production material to migrate.

### Observed implementation seams at the baseline

- Core `Tags/DocumentTags.swift` (`parse`, `sortDate`) and `Tags/GeneratedTags.swift` (`allTags`,
  `machineDate`) carry one date. Repeated bare components can cross-pair; `Tags/TagEditing.swift`
  (`delta`, `GroupTagSummary`) needs explicit role-aware edits.
- Reader `Core/LibraryFilter.swift` (`LibrarySort.rank`) sorts that date. **Its `LibraryFilter.matches`
  has no date-range fields today**: date filtering is new work, not just extending an existing date predicate.
- Processor `Tagging/DocumentSegmenter.swift` (`DocumentSegment`) has no enclosure relation;
  `Tagging/TagGenerator.swift` (`generateDateOnly`, `parseTagResponse`) returns one date. Thread both values
  through manual tag data, `OCRProcessor+Tagging` and `SegmentJSONBuilder.buildData`, including recovery.
  `OCR/PDFGenerator.swift` (`makeTextPage`) currently receives no generated document date;
  `mergeDocumentPDFs` concatenates already rendered pages. Add a post-tagging metadata-rendering seam.
- Notes `Store/Item.swift` (`sortDate`), `Store/FrontMatterCodec.swift` and `Models/NotesFilter.swift`
  (`matches`) use one primary value. Extend `Index/NotesIndex.swift` and `Core/NotesTagProjector.swift`
  with role-aware storage/ownership rather than duplicating the list row.

### Implementation and proof after the decision

Implement the chosen contract coherently across ArchiveCore, Processor, Reader and Notes, updating the
normative tables above at that point. Core owns role-labelled values, parsing, formatting and matching;
apps retain their audited write adapters. Include all date-filter consumers (live filters, saved smart
folders, search/year facets), cache rehydration, sort fallback, inspectors and manual tagging; serialization
must preserve each value's precision, uncertainty and role through interrupted/resumed processing.

Tier-2 remains mandatory: a separate adversarial review plus scratch-copy functional proofs for tag/PDF
writes, Notes serialization/projection, and relation persistence; build/test all three apps and Core,
run Reader's write-surface lint, and verify visible controls in the off-screen VM. Include these cases:

- Different dates, identical dates, own-only, sent-only, speculative dates and all four precisions.
- A bounded range cannot match by using one date for each bound; sorting stays stable under a sent-date edit when an own date exists.
- Malformed/conflicting tokens, role-looking subjects, duplicates, clear/edit/undo and unreadable tag guards;
  untouched tag multiplicity, colour and PDF data-fork bytes survive Reader edits.
- Several enclosures, continuation pages, a missing cover date and a disputed relation; no neighbour inference.
- PDF source-date lines strip from the OCR body correctly without consuming real body text or classification.
- Notes save/reload/index rebuild and smart-folder matching on each role, one row per UUID, with projection
  confined to a scratch note store. The dormant import does not run.

**Next step:** owner answers the three behaviour choices above (`W37.dual-date-owner-ok` in the trackers).
Then implement and prove the chosen design; this proposal checkpoint does not complete W37.dual-date.
