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
| Read/write color label | `.labelNumberKey` (Int) | both (`finderLabelIndex` / `FinderLabel`) |
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
  token (`"Red"`, `"Green"`, …, one of Finder's seven) in the tag array are two representations of the
  same fact. **Verified:** keeping the color-name token in the array and writing only `.tagNamesKey`
  **preserves the existing `labelNumber`** without writing it — except in a sandboxed app on macOS 27,
  where it came back `0` (measured 2026-11-12) and the writer's §7 drift restore puts it back. Processor still writes `.labelNumberKey`
  explicitly (`MacOSTagger.applyTags`: the colour the user chose for the item type, or `0` when none);
  Reader writes it **only** when a delta changes color (`TagWriter` §7), otherwise restores drift. The
  colour is the user's display choice, never the item type (§Item type).
- **Every tag a write leaves alone keeps its own colour.** Each entry of the raw tag attribute
  (`com.apple.metadata:_kMDItemUserTags`) carries the tag's own colour after a newline (`"Purple\n3"`).
  A names-only `.tagNamesKey` write lets macOS choose those colours, and **on macOS 27 a sandboxed app
  gets none** (measured 2026-11-12, host and VM: `"Purple\n3"` → `"Purple\n0"`; unsandboxed, any tag not
  in the local Finder tag list lost its colour too). So `CoordinatedTagWriter` (§7a) puts back, exact
  name and occurrence by occurrence, the entry each surviving tag had before the write, Finder's colour
  names included (a colourless `"Red\n0"` stays colourless: the name never sets the colour, §Item type);
  a tag the write adds keeps whatever macOS gave it, so an undo that re-adds a removed tag does not bring
  back its own colour in a sandboxed app. This is separate from `labelNumber` above, which lives in the
  file's Finder info.
- **No search index is ever tag truth.** The filesystem xattr read through `.tagNamesKey` is the only
  authority. Spotlight's `kMDItemUserTags` was the Reader's discovery mechanism until `W26.walk2` replaced
  it with a direct walk (`ArchiveCore.CorpusWalker`) plus a disposable `LibraryIndex` cache and FSEvents;
  it is lossy and stale, and the same rule binds the cache that replaced it. Never build a write array
  from a cache or an index — only from a fresh per-file read (Reader `TagWriter`/CLAUDE §Safety-5).

---

## Tag facets

A file's tag array intermixes the facets below. Classification into facets is **display / sort /
filter only** and **must never drive a destructive write** — subjects can collide with any facet
token (a subject literally `1984`, `P7`, `Read`, `Folder`), so a mis-classified facet is acceptable
(the user corrects it in the UI) but a facet-driven token removal is not. Reader's canonical parser
is `DocumentTags.parse` (`Core/DocumentTags.swift`); Processor emits them from `GeneratedTags.allTags`
(`Tagging/TagGenerator.swift`).

Parse order matters (read-state / quality — incl. the legacy `P7`–`P10` priority alias — / month / day are
recognized **before** the bare-number year test, so `Q2`, `P7`, or `Day 25` is never taken for a year).

| Facet | Exact string form | Cardinality | Notes |
|---|---|---|---|
| **Year** | bare digits, e.g. `1980` | 0–1 | Processor's LLM prompt forces a **4-digit** year and never null for a dated doc. Reader's `parseYear` accepts **3–4 digits** (medieval-friendly: `800`, `1215`). See discrepancy #1. |
| **Month** | `MM Month`, e.g. `03 March` | 0–1 | `MM` = 1–12 as one or two ASCII digits (`3` or `03`; no sign, no longer zero run), name must match that month (case-insensitive). Processor applies `capitalizeFirstLetters`, so it is emitted title-cased. Month is written **only when explicit in the doc**, never inferred. |
| **Day** | `Day N` (unpadded), e.g. `Day 25`, `Day 1` | 0–1 | N = 1–31, one or two ASCII digits (a reader also takes `Day 05`; `Day 013`, `Day +5` stay subjects). Often absent. |
| **Decade** | `NNNNs`, e.g. `1970s` (a 3–4 ASCII-digit run, no sign, whose **last digit is `0`**, then a **lowercase** `s`; medieval-friendly `970s`) | 0–1 | An **approximate** date spanning ten years. **Mutually exclusive with Year** — a concrete Year supersedes a Decade. Recognized alongside the bare-number Year test (the trailing `s` means it can never match the digits-only Year test, so order is immaterial). Written by the Processor **only** when the user types it into the manual tag dialog's Year field; the LLM tagger never emits it. Reader parser: `DocumentTags.parseDecade`. |
| **Date Uncertain** | literal `Date Uncertain` | 0–1 | Flags a **speculative year** — the file _usually still carries a Year tag_. Not "no date." |
| **Sent With** *(W37.dual-date)* | `Sent With 1958`, `Sent With 1958-03`, `Sent With 1958-03-12` or `Sent With 1950s` | 0–1 | The **covering letter's** date on an enclosure that has its own date. ONE whole-value token so its precision never cross-pairs with the item's own Year/Month/Day. Exact, case-sensitive prefix `Sent With `; 3–4 ASCII year digits, no leading zero; zero-padded month/day that must exist (Gregorian); decade `NNN0s`. Anything else (`sent with 1958`, `Sent With 1958-02-30`, `Sent With Love`) stays a verbatim subject. Two valid tokens: last wins, the earlier is demoted to a subject and flagged (`dateAmbiguities`, below), never combined. Core: `ArchiveDate` / `SentWithTag` (`Tags/ArchiveDate.swift`). |
| **Sent With Date Uncertain** | literal `Sent With Date Uncertain` (exact case) | 0–1 | Speculative sent-with date. Independent of `Date Uncertain`; written only beside a `Sent With` value, and cleared with it. |
| **Quality** *(the rating facet)* | exactly one of `Q1` `Q2` `Q3` (higher = better) | 0–1 | **The single importance/quality rating (W19, 2026-07-18) — MERGED with + supersedes the legacy Priority facet** (`Q3` = old `P10`). A human 0–3 rating; **`Q0`/unrated writes NO tag** (absence *is* 0 stars, so the wire only ever carries `Q1`/`Q2`/`Q3`). Human-set everywhere, **never LLM-emitted**: Notes (front-matter `quality`), Reader (edit), Processor's interactive tagging (Live Capture tag card + Process Files manual tagging), and the **phone companions** (per-page/segment — the old priority control now emits `Q`). Q-prefix can never collide with the digits-only Year test. |
| **Priority** *(legacy → Quality)* | `P7`–`P10`, on pre-W19 files only | 0–1 | **RETIRED — merged into Quality (W19, 2026-07-18).** No longer written by any app or companion. **Read-only alias:** `P8`/`P9`/`P10` parse as `Q1`/`Q2`/`Q3` and `P7` as unrated, so pre-W19 phone-captured files still resolve without a corpus rewrite. |
| **Read state** | `Read` or `Unread` | 0–1 | Matched **exact whole-string, case-insensitive**. Processor stamps `Unread` **last** on new real-tagging output. |
| **Subject** | free-ish strings, title-cased | ~2–6 | Everything not claimed above, kept **verbatim**. Case variants are one tag (Safety rule 4). Processor caps the LLM at 6 (`TagGenerator.parseTagResponse`). OCR failures carry `OCR Failed`; a person flags inadequate transcription with `OCR Poor` (below). |
| **Item type** | literal `Box` or `Folder` (exact spelling) | 0–1 | A photo of a box label or of a folder label (§Item type). Last token wins; an earlier one reads as a subject, but the words are reserved, so setting the type removes every `Box`/`Folder` token. `box`, `BOX`, `" Box "` are subjects. |
| **Color label** | `.labelNumberKey` + color-name token | 0–1 | The user's own display choice, any of Finder's seven, **none by default**. It never marks the item type, except in material made before the type tokens, read through a per-root setting (§Item type). |

**Poor OCR (W44.reocr-spec).** `OCR Poor` is an ordinary Subject token, independent of the
Q1–Q3 importance rating and the execution-failure subject `OCR Failed`. Only an explicit person's
action sets it; models, confidence scores and failed reads never set it. Match the whole token using
`tagKey`/`isSameTag` (case-folded), never a substring. New feature additions use canonical `OCR Poor`;
model-response parsing rejects this token in all tag-bearing fields, even with a controlled vocabulary;
if already present, keep every spelling and occurrence verbatim. Generic subject editing keeps the
existing subject spelling rules. `DocumentTags.hasPoorOCR` is a read-only projection over `raw`, not
a new facet, and does not consume those subjects.

Writes use the apps' audited tag adapters and occurrence-aware deltas/undo. A read error is never an
empty list. Removal targets only that token's identity, preserving unrelated subjects (including
`OCR Failed`), dates, ratings, Read/Unread, colour and PDF bytes. Feature flagging/filtering, the shared
flag-generation protocol and acceptance clearing ship in W44.reocr-processor/reader; this contract
alone does not authorize an automatic flag clear. Acceptance may clear only the reviewed generation;
cancel/reject/failure leaves the flag. Improve OCR also works without a flag and never adds it implicitly.

**Two tokens for one date facet.** Year, Month, Day, Decade and Sent With are 0–1. When a file carries
two tokens that parse as the same one, the **last wins** and each earlier one is demoted to a subject,
verbatim; a malformed `Sent With <digit…>` token stays a subject too. Nothing is combined or rewritten.
`DocumentTags.dateAmbiguities` names each such facet, the token it reads and the ones set aside, so an app
can flag the file for review (Reader: the Date cell, the ⌘I sheet and an "ambiguous dates" filter). A Year
beside a Decade is not ambiguous: the Year supersedes it. Display and filter only; it never drives a write.

**Subject-collision rule (critical).** Facet detection is heuristic and lossy-by-design; the raw
array is the source of truth. A subject that happens to equal a facet token must survive: e.g. a
document about the "Red Scare" with **no** red label keeps `Red` as a subject (Processor
`MacOSTagger.applyTags` `colorIsAuthoritative` path; Reader `DocumentTags.parse` color check gated on
the file's actual `labelNumber`).

### Item type

W40.suite-item-types (owner's Reader notes, 2026-11-10, point 15). **Box and Folder are item types, and
colour is the user's choice.**

- **The record is the token.** A box-label photo carries the tag `Box`, a folder-label photo `Folder`:
  exact case, whole token, the same words as the page-2 Classification values `Box` / `Folder` (§2-page
  PDF). `ArchiveCore.ItemType` reads it; `DocumentTags.itemType` / `itemTypeToken`. The Processor writes
  it on every real-tagging path (it already wrote these words as subjects); the Reader writes it only on a
  deliberate user action (Inspector ▸ Item type) through `TagWriter`, as a token delta.
- **Colour is a display setting.** Processor ▸ Settings ▸ Tagging has a Box colour and a Folder colour,
  each none (the default for a new user) or one of Finder's seven; the chosen colour is written as the
  label beside the token. The Reader's list marker uses its own Options ▸ Item types colour per type, or
  the type's name when none. No app names the type by a colour.
- **Material made before the tokens.** Before this change the Processor marked the type only with the
  label (Red = 6 a box, Purple = 3 a folder); on the owner's 5,000-file sample 75 files carry Red and 186
  Purple, and none a `Box` or `Folder` tag. The Reader keeps, per archive root (app-side, keyed by the
  root's preference GUID, never in the corpus), which colour meant which type, asked once when a root is
  chosen and changeable in Options; `DocumentTags.parse(…, colours:)` reads a type from the label through
  it (`itemTypeFromColour`). The token wins over the colour. Setting a type in the Reader writes the token
  and clears a label that still reads as another type under that setting, so the file reads as asked;
  clearing the type clears such a label too. No migration is written: no app output is kept (owner,
  2026-08-01), and the pre-app corpus is read through the setting rather than rewritten.
- **One vocabulary with the page kinds.** The item type says what a whole file is (a label photo, not a
  document); it is the file-level form of the Classification's `Box` / `Folder`, while `Document Start` /
  `Continuation` say where a document's pages begin and stay page-level. **Kind** (W44, per text page:
  handwritten, typewritten, printed, forms) and W42.int-s3's kinds of page (adding clippings, newspapers,
  registers) describe how a page's text is written and which reader suits it; they are a separate axis. A
  Box or Folder item may carry a Kind for its label's text, and a Kind never implies an item type.

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
- **Sent-with fallback (W37, owner 2026-10-05).** The item's OWN date sorts. Only when it has none does
  the `Sent With` date's key sort it (`DocumentTags.sortsBySentWith`), and the UI labels that fallback.
  A covering letter never acquires an enclosure's date, and an enclosure's own date is never replaced.
- **Date filters match either date.** `ArchiveCore.DateRangeFilter` tests each role's key on its own
  (`DocumentTags.dateKeysByRole`): a file matches once if its own OR its sent-with date is inside, and
  both bounds must be met by the SAME value — dated 1950, sent 1970 never matches 1960–1965. Year-only
  and decade values keep their sort-key position; this is not interval overlap.
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
<original filename>            ← source name (control chars flattened to spaces), any image ext; may be ABSENT
<Provider> · <Model> · <D Month YYYY>   ← separator is U+00B7 with surrounding spaces; date e.g. "9 March 2026"
Classification: <value>        ← OPTIONAL segmentation value; absent when unknown
Kind: <kind>                   ← OPTIONAL: handwritten, typewritten, printed or forms; absent when unknown
Document date: <display>       ← OPTIONAL (W37); the document's OWN date, e.g. "Nov 3, 1957"
Sent with: <display>           ← OPTIONAL (W37); the covering letter's date, e.g. "Mar 12, 1958"
                               ← blank line
<body text…>                   ← or "No text returned by model." (+ error) on OCR failure
```

- `<Provider>` is `model.provider.rawValue` (`Anthropic`/`Google Gemini`/`Mistral`/`OpenAI`/`Apple Vision`/`OpenRouter`),
  a custom gateway display name, an imported institutional cluster's name, **or** `Local CLI Agent (<tool>)` for a
  subscription-authenticated CLI. Treat this position as free-form. An OpenRouter model's name carries its pinned
  provider and precision, e.g. `Qwen3-VL 235B (deepinfra fp8)`. A Local Agent's model position is its explicit CLI
  override or `CLI default`, never the selected direct-provider fallback. The on-device backend writes
  `Apple Vision · macOS Vision` in the header's provider/model positions.
  Imported text (W41.app-institutional-compute) uses the per-page `_meta.cluster` name; for example,
  `FarmShare · Qwen3.6-27B-FP8 (FP8 weights, fp8 KV cache, job 1849739)`, or another institution's cluster.
  All newly written provider/model labels use `ImportedReading.headerComponent`: flattened to one line,
  with middle-dot tokens replaced by commas so they
  cannot introduce the header's separators. Missing/blank cluster provenance is not imported. Matching is by the
  input image's SHA-256, never its name.
- **Classification — verified values (exact strings):** `Document Start`, `Continuation`, `Box`,
  `Folder`. (These are `DocumentClassification.displayName`; the enum's Codable rawValues
  `document_start`/`document_continuation`/`box_label`/`folder_label` appear only in JSON sidecars,
  **never** in the PDF text.)
- **Classification may be ABSENT.** It is written only when the Processor knows it; consumers **must
  degrade gracefully** (fall back to filename-sequence order + manual grouping). Never build a core
  behavior that assumes it exists.
- **Classification is read from the header only** (W40.fix-core-classification-from-body): page 2 must start
  `Extracted text.`, and the line must directly follow the provider line, before any source-date line. A
  `Classification:` line in the OCR body (an archival security marking), on another page or in the file name
  is not the classification. PDFKit drops the blank separator from a real page's text, so the header ends at
  the first line that is not a header line; a wrapped provider line may take one continuation line.
- **Kind (W44.reocr-spec)** is per text page, independent of segmentation Classification. Exact IDs:
  `handwritten`, `typewritten`, `printed`, `forms`; labels Handwritten, Typewritten, Printed, Form or table.
  New output writes the explicit person's choice when supplied to `PDFGenerator.generate(pageKind:)`,
  otherwise the classifier's stored `pageReader.kind`, otherwise a validated imported kind. A known
  classifier kind is written even when it did not change the reader. Missing, invalid (including imported
  `mixed`), repeated or conflicting Kind is unknown, with Core diagnostics; absence is never guessed
  printed. Newspaper/register/script attributes belong to settings, not new Kind IDs. No new classifier
  call is implied on routes that have no classification; they leave Kind absent. No migration is written
  because there is no app-produced production material to migrate.
- **One structured header parse.** Core `PDFHeaderParser.parse` drives stripping, classification,
  provenance, Kind and source-date extraction together. On unrotated text pages, PDFKit selections
  recover physical header-line order (its `page.string` can group short lines across wide provenance).
  Strip only the header selections' exact character ranges from the original string; keep body order
  and `fullBody` unchanged. Rotated pages or unavailable/invalid selections use conservative string
  parsing. Require the exact sentinel as the first physical line.
  Inspect only the immediately following provenance slots (one optional filename, allowing PDFKit's
  two-line filename split), with at most one provenance continuation completing the processing date.
  A completed provenance line may follow a dot-containing filename in the first prefix slot;
  a malformed three-position line is retained unless an explicit filename extension disambiguates it;
  once the slot after the filename contains provenance, even malformed, it cannot be replaced by later
  text. Never search the rest of the page for fields. Optional fields follow the displayed order; stop at the first
  non-header line or blank separator. Repeated/late Kind is consumed but diagnosed and remains unknown;
  other repeated/out-of-order fields begin the body. Preserve raw malformed provenance for inspection,
  with unknown structured provenance: require exactly three separator-delimited, nonempty positions and
  a valid `d MMMM yyyy` processing date for `PDFReaderProvenance`. Provider/model are display strings,
  including cluster and pinned precision labels, never enum lookups or executable routes.
- **Ambiguity when PDFKit drops the separator.** A body starting immediately with a valid-looking
  optional field in the expected slot can be read as header metadata. This format cannot distinguish
  that case. A later lookalike, or a field following a retained blank separator, stays in the body.
  The filename slot is opaque, even when it starts `Kind:` or `Classification:`. A filename that is
  itself indistinguishable from a complete provenance line has the same prefix ambiguity; the first
  complete candidate wins. These are parser limits, not evidence of another classifier result.
- **Source-date lines (W37.dual-date).** `Document date:` / `Sent with:` are the SOURCE document's dates
  (`ArchiveDate.display` form), distinct from the processing date. They are output-time snapshots;
  fresh Finder tags remain authoritative. Exact case-sensitive prefixes, after Classification/Kind,
  consumed only within the same ordered header block. Written only where dates are known at render
  time (Live Capture); Process Files does not rewrite finished PDFs to add them.
- **Per-page metadata and mixed summaries.** `ExtractedContent.textPages` records zero-based physical
  text slots 1, 3, 5… with optional `PDFPageHeader`. Missing headers stay represented. Kind and full
  provenance summaries are unknown when all slots are unknown, uniform only when every slot agrees,
  and mixed for differing values or a known value beside an unknown. This metadata does not prove a
  valid image/text pair. Both app extractors expose these page values. Existing `fullBody` retains
  all pages and headers for Reader FTS; `strippedBody` and top-level classification retain their
  page-2-only behavior until their consumers are explicitly changed. Do not assign page 2's metadata
  to every image of an interleaved file. Actual-reader provenance precedence stays imported, fallback,
  routed reader, Local Agent, gateway, then run model. This item adds no corpus content writer to Core.
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
   the **only** change to existing archive files, via the audited `Core/TagWriter.swift`.
   **Named exception (W40.root-marker-auto):** choosing a folder — in the Reader, or with Archive
   Notes' Choose Archive Folder… — creates `.archive-suite-root.json` once at the granted root through
   ArchiveCore `RootMarker.ensure` if it is absent; it is never rewritten. Reopening at launch, browsing,
   tagging and ordinary copying do not create it. No existing archive file is touched. A root with no
   marker (chosen before this rule, or removed) gets one at the next choice or archive-link copy; that
   is a new identity, so old links no longer resolve. Notes never creates one with a link in hand.
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
4. **Whole-string, case-insensitive token matching: tags that differ only in case are ONE tag**
   (W40.fix-tags-case-insensitive, owner 2026-11-04). Never substring — removing `Unread` never touches
   a subject `"Read later"`, removing `Lincoln` never touches `Lincolnshire`. Tokens compare by their
   identity key, `tagKey` (full Unicode case folding, no locale; accents are not folded), **except a
   facet-shaped token**, whose key is its exact spelling (`keepsExactCase`: a rating `Q1`–`Q3`/`P7`–`P10`,
   a date facet incl. `Date Uncertain` and `Sent With …`, a Finder colour name as Finder spells it
   (`Red`, `Green`…), the item type `Box`/`Folder`), so the rating `Q2` and a fiscal-quarter subject `q2`, the
   colour token `Red` and a subject `red`, or the type `Box` and a subject `box`, stay two
   tags and a facet edit never adds, skips or removes the other; `Read`/`Unread` fold as before. Add-dedup
   (`isSameTag`: adding `lincoln` to a file carrying `Lincoln` writes nothing), removal and rename
   (`shouldRemoveTag`: every case of the tag goes), and every grouping, count, filter and suggestion
   (`tagCounts`, ArchiveCore `Tags/TagIdentity.swift`). The key is never written: **each file keeps the
   spelling it has**, and a **new** tag is written in the spelling the library (Reader) or the tag
   vocabulary (Processor) already uses for it (`NavigationModel.spellingForNewTag`/`TagVocabulary.spelling(of:)`), as
   typed only when the tag is new. A case-only rename (`lincoln` → `Lincoln`) is how a tag's spelling is
   changed; it re-spells every case of it. Undo and redo stay **exact** (the occurrence inverse restores
   each spelling the file had), and so does the §8 verify. Facet parsing (`DocumentTags.parse`) is
   unchanged: its own case rules (Month name, `Read`/`Unread`, exact-case `Sent With`) stand. Notes'
   managed-tag projection (`NotesTagProjector`) still matches its own ledger exactly, by design: it
   removes only the tokens it wrote, so folding could take a nearby user tag.
5. **Lossless writes.** `new = (fresh − remove) + add`, every untouched token preserved verbatim; a
   no-op delta writes nothing (no mod-date churn). **Never** build the write array from any index or
   cache — not Spotlight's `kMDItemUserTags` (the Reader's discovery mechanism until `W26.walk2`), and
   not the `LibraryIndex` rows that replaced it. Only a fresh per-file `.tagNamesKey` read.
6. **`Unread` stamped last, once.** In real-tagging modes only (`.automatic`/`.autoDate`/
   `.human`; `autoDateManualSeg` was folded into `autoDate` by W36.seg-opt-review, 2026-10-11), Processor drops any incoming `Unread`, writes all other tags,
   then appends exactly one `Unread` as the final element (`MacOSTagger.applyTags`, lines 42–66).
   "No tagging" and "Copy source tags" modes stamp nothing and pass source tags through verbatim.
   "No tagging" means no *generated* tag (no LLM subject or date, no app colour, no `Unread`); in
   Live Capture it still writes what a person set: the tag card's subjects, date and Quality, and the
   phone's date and Quality (W40.fix-live-vision-drops-card-tags). With nothing set, no write at all.
   Box and folder photos stay untagged in this mode: without their type token, a year or Q would make a
   label photo read as a rated document.
7. **App-authoritative type and color.** In real-tagging modes Processor writes the `Box`/`Folder` token
   for a label photo, and `.labelNumberKey` from the colour the user chose for that type (or `0` to clear
   a stale swatch, which is also what a new user, with no colour chosen, gets). A subject string equal to
   a colour name is **never** promoted to a color label (`colorIsAuthoritative` path). Reader writes
   `.labelNumberKey` only when a delta changes color.

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
| Item type (`Box`/`Folder`) + the user's colour | `Tagging/TagGenerator.swift`, `OCR/OCRProcessor+Tagging.swift` (`structureTag`, `authoritativeColor`), `Tagging/ItemTypeColourSetting.swift`, `Tagging/MacOSTagger.swift` (`finderLabelIndex`) | ArchiveCore `Tags/ItemType.swift` (`ItemType`, `FinderLabel`, `ItemTypeColors`) + `DocumentTags.itemType`; Reader `Core/ItemTypePreferences.swift`, `Core/TagWriter.swift`, `Views/TagEditorView.swift` (Item type) |
| **Sent With** date (W37) | `Tagging/DocumentSegmenter.swift` (`enclosureOf`), `OCR/OCRProcessor+Tagging.swift` (cover date → `GeneratedTags.sentWith`), `Views/ManualTaggingSheet.swift` | ArchiveCore `Tags/ArchiveDate.swift` (`ArchiveDate`, `SentWithTag`, `DateRangeFilter`) + `DocumentTags.sentWith`; Reader `Core/LibraryFilter.swift` (year range), `Views/TagEditorView.swift` (⌘I sheet); Notes front-matter `additional_dates` → `NotesTagProjector` |
| Chronological sort key | (n/a — Reader-derived) | `Core/DocumentTags.swift` (`sortDate`; own date, sent-with fallback) |
| 2-page PDF + page-2 header | `OCR/PDFGenerator.swift` (`makeTextPage`) | **Shared:** `ArchiveCore` `PDFHeaderParser` (extract, `fullBody`/`strippedBody` split, `parseClassification`, structured per-page metadata and summaries). Reader indexes `fullBody`; Processor shim uses `strippedBody`. `PDFFormatStatus` also in Core. |
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

## W37.dual-date — enclosure dates (design record, 2026-10-05; IMPLEMENTED 2026-10-06)

**Implemented.** The owner chose all three recommendations below on 2026-10-05; the normative rules
now live in the tables above (facet rows *Sent With*, the sort-key section, the page-2 header). This
section is kept as the design record and for its proof list. Baseline: `3465e15`.

**How enclosures are identified (as built).** The OCR prompt lets the model add an optional
`[enclosure]` marker on a `[document_start]` page that begins a separately dated document sent with the
letter before it (`OCRPrompt.parseEnclosureFlag`, header lines only). `DocumentSegmenter` turns a marked
page into `DocumentSegment.enclosureOf` (the covering segment), never across a box/folder label or an
unclassified page and never from adjacency alone; consecutive enclosures share one letter. The
enclosure's `Sent With` value is the covering letter's own date at tagging time (none if the letter is
undated — no neighbour is borrowed). The manual tag sheet shows the proposal, can clear it, and takes a
typed sent-with date. Mistral/Vision and pre-OCRed classification-only runs propose nothing. The owner already required two dates for an enclosure with its own date; the open
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

Proofs as shipped: ArchiveCore `DualDateTests` + `PDFHeaderParserTests`; Reader `DualDateLibraryTests` +
the scratch-file `TagEditingIntegrationTests.testApplySentWithEditsOnDiskPreserveEverythingElse`; Notes
`DualDateTests`; Processor `scripts/test-dual-date.sh` (`DualDateTestDriver`, headless, $0).
