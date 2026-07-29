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
| Spotlight view | tags surface as `kMDItemUserTags` (query only) | Reader `ArchiveLibrary` |

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
- **Spotlight `kMDItemUserTags` is lossy/stale** and is used only to _find_ files. Never build a
  write array from it (Reader `TagWriter`/CLAUDE §Safety-5).

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
| **Suite marker** | literal `ArchiveSuite` | 0–1 | Stamped by Archive Notes onto its own `.md` files (via `NotesTagProjector`) to mark them as suite-managed. **Not emitted by Reader or Processor.** Recognized by `ArchiveSuiteMarker.isMarker` (case-sensitive exact match). The subject-collision rule below applies: a user document with a subject literally named `"ArchiveSuite"` is handled at the projector level, not by the marker recognizer. |

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

- `<Provider>` is `model.provider.rawValue` (`Anthropic`/`Google Gemini`/`Mistral`) **or** a custom
  gateway display name — treat as free-form.
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
   no-op delta writes nothing (no mod-date churn). **Never** build the write array from Spotlight
   `kMDItemUserTags`.
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
| **Notes date facets** (Year/Month/Day/Decade) | (n/a) | Notes `NotesTagProjector` projects its front-matter `date`+`datePrecision` into the **existing** date facets (reuses `ArchiveCore.DocumentTags.sortDateKey`; no new vocabulary). |
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
