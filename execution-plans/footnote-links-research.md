# Clickable Footnote and Endnote Links in Output PDFs — Research Report

**Item:** `W49.proc-footnote-links` (`W50.v2-release`, research only — no build)
**Origin:** Owner walkthrough of 2026-11-19 (call 23), carried forward from Vision OCR's `FEATURES.md` ("Clickable footnote and endnote links", 2026-08-13).
**Date:** 2026-11-27

---

## 1. Executive summary

Adding clickable `/Link` annotations between in-body footnote/endnote markers and their notes is **mechanically ready** in the current Suite — every piece of byte-preserving PDF object surgery that did not exist in August 2026 has since shipped (`VisionOCRKit/Annotations.swift`, `VisionOCRKit/JBIG2.swift` `setOutline`, and `ArchiveProcessor/SearchableArchival.swift`).

The hard part is not writing links; it is **finding tiny superscript markers reliably on real scans** and **mapping per-chapter endnotes with zero silent mislinks**. Splitting the feature reveals two very different problems:

1. **Same-page footnotes (bottom of page):** Needs **no LLM**. Sub-line Vision geometry (`VNRecognizedText.boundingBox(for:)`) plus deterministic monotonic sequence matching on one page can pair them offline at `$0` with a strict abstention gate. However, the reader benefit is modest because the note is already visible on the same page (helpful mainly when zoomed in).
2. **Backmatter endnotes (scanned monographs):** This is the high-value historian workflow ("following an argument without flipping 250 pages"), and it is genuinely harder. Numbering usually restarts per chapter, only 11 of 78 corpus documents carry a PDF outline, and backmatter headings vary wildly (`Notes to Chapter 3`, `Notes to Pages 45–62`, `Notes to "The Corporation"`). Here a **single compact text-only LLM call per book** via `LLMTextClient` (never sending page images, `<$0.01`/book) earns its place for chapter-to-notes alignment — strictly behind a deterministic verifier that refuses any chapter whose marker sequence fails monotonic alignment.

**Two codebase findings discovered since the 2026-08-13 note:**
- **Archive Processor emits PDF/A-2b** (`SearchableArchival.swift`), unlike standalone Vision OCR. Any `/Link` annotation added to a PDF/A-2b output must satisfy ISO 19005-2 annotation rules (`/F 4` Print flag set, Hidden/Invisible/NoView cleared, direct `/Dest` or `/GoTo`, `--newline-before-endstream`).
- **Archive Reader displays single-page PDF slices** (`ReaderPDFView` in `PDFPaneView.swift` runs `.singlePage` on a per-page slice). Native PDF `/Link` → `/Dest` jumps work immediately in Preview, Skim, Acrobat, and iPad readers, and same-page jumps work anywhere, **but cross-page clicks inside Archive Reader will not turn the page** unless Reader intercepts `/Link` hits against the full document and routes them through `DocumentViewerModel` + `pageHistory` (which also makes `⌘[` Back return straight to the paragraph).

---

## 2. Finding markers and notes

### 2.1 What geometry the engine currently produces (and what is missing)

- `packages/VisionOCRKit/Sources/VisionOCRKit/Recogniser.swift` (`recognise(_:orientation:settings:)`) currently records **line-level** `SearchableWriter.Observation` values (`boundingBox`, `text`, `confidence`, `quarterTurns`, `region`), normalised to a top-left origin.
- `VNRecognizedText` (`candidate = observation.topCandidates(1).first`) already supports **`candidate.boundingBox(for: Range<String.Index>)`** — per-word and per-character boxes, explicitly noted as an unused capability in `Recogniser.swift` lines 43–45.
- `packages/VisionOCRKit/Sources/VisionOCRKit/TextLayer.swift` passes only line-level `TextLayer.Lines` into `ArchiveProcessor` (`PDFGenerator` / `CompressedPage`).

To detect superscripts without slowing down normal OCR, `Recogniser` should **not** query `boundingBox(for:)` on every character of every page. Instead, when footnote linking is enabled, it only inspects candidate tokens in each line (and standalone micro-observations sitting slightly above a line):
- trailing digits attached to a word or closing punctuation (`argument.14`, `“policy”7`, `states,3`),
- standalone 1–3 digit or note-symbol (`*`, `†`, `‡`, `§`) tokens.

### 2.2 Geometric signature of an in-body marker

Text regex alone fails on dates (`1954`), quantities, section numbers, and running headers. Sub-line geometry disambiguates a superscript relative to its host body line `(y_line, h_line)` (top-left normalised coordinates):

- **Height ratio:** `h_tok <= 0.65 * h_line` (a 5–7 pt superscript inside 10–12 pt body type).
- **Raised bottom edge:** the token's bottom (`y_tok + h_tok`) sits clearly above the body baseline — roughly at or above `y_line + 0.65 * h_line` (whereas normal digits sit down at `~0.80–0.90 * h_line`).
- **Context check:** immediately follows a word, punctuation, or closing quote (not inside a date/equation/table column, and not in the top/bottom running-header margin band).

**Known failure modes on archival scans and monographs (must be measured before building):**
1. **Dropped tiny superscripts:** At ≤200 DPI or in soft microfilm/photocopy scans, Vision drops 5–6 pt superscripts completely, or merges a `1` into adjacent punctuation (`."` → `.'`).
2. **Superscript misreads:** Vision commonly reads raised `1` as `l`/`I`/`'`, `2` as `²`/`z`, `3` as `³`, or `0` as `°`. Unicode superscripts (`¹²³⁴⁵⁶⁷⁸⁹⁰`) are easy to normalise; letter substitutions (`l` for `1`) are only safe to recover if *strictly sandwiched* in a monotonic sequence (`... 10, [l→11?], 12 ...`) with matching superscript geometry.
3. **VLM-aligned pages (`TextLayer.aligned`):** When a cloud or local VLM reads the page and `Recogniser.alignedReading` projects its text onto Vision's line boxes, the VLM may transcribe a superscript that Vision never boxed. Without a Vision sub-line box, there is no exact `/Rect` for the marker; options are (a) link only markers with a verified Vision box (cleanest, zero misplaced boxes), or (b) run a targeted local connected-component ink search in the 1-em window right of the preceding word's box (extra complexity, only worth considering if Phase 0 shows high Vision miss rates on otherwise clean scans).
4. **Two-column and cropped pages:** `SearchableWriter` already tracks `region` (pasted-up strips) and gutter splits (`splitAtGutter`), and `Flattener` maps crop boxes onto `fullBox`. Marker ordering must follow reading order (column by column, not naive top-to-bottom across a gutter), and `/Rect` coordinates must be emitted in the **final published page's user space** (same coordinate frame as `SearchableWriter.compose`).

### 2.3 Finding the notes (targets)

The two layouts differ sharply:

| Property | Bottom-of-page footnotes | Backmatter endnotes |
|---|---|---|
| **Where they live** | Lower portion of the same page (below a short horizontal separator rule, a vertical gap `>= 1.5×` leading, or a drop to `70–85%` of body line height). | Contiguous run of pages near the end of the PDF (before Bibliography/Index), under a `Notes` / `Endnotes` heading, with smaller type (`~75–85%` of body height) and dense leading numbers `1.`, `2.`, … |
| **Start of each note** | Line left-aligned (or hanging-indented) with `^(\d{1,3})[.\s]` or note symbol, matching the page's body sequence. Multi-page continuation text sits *above* the first numbered note on the next page. | Same line-start pattern, grouped under sub-headings (`Chapter 1`, `Chapter One`, `1. Introduction`, `Notes to Pages 12–34`) where numbering usually resets to `1` per chapter (occasionally continuous across the whole book). |
| **Target destination** | Same page, `/XYZ null <noteTopY + margin> null`. | Target backmatter page, `/XYZ null <noteTopY + margin> null` (with a small ~12 pt upward padding so the viewer does not clip the note's top line). |
| **Hard failure modes** | Multi-column footnote blocks; unnumbered editor's notes; table footnotes using `1, 2, 3` inside a page that also has prose footnotes `14, 15`. | Footnotes-by-page-number (`p. 42, "the union": ...` — no superscript numbers at all; **must abstain**); notes restarting per section rather than chapter; missing/unrecognised chapter title pages; appendix notes. |

---

## 3. Is an LLM needed to pair markers with notes?

**Answer: No for same-page footnotes; optionally yes (one tiny text-only call per book) for backmatter endnotes — and never without a deterministic verification gate.**

### 3.1 Same-page footnotes — deterministic only (`$0`, offline)

On a single page, let `M = [m_1, ..., m_k]` be the geometrically-validated body markers in reading order and `N = [n_1, ..., n_j]` be the bottom-zone note anchors in reading order.

- **Exact / strict-subsequence match:** If every number in `M` is unique on the page, strictly increasing (or consecutive across pages), and matches a unique anchor in `N` with the same order, pair them directly.
- **Partial recovery:** If one body marker was missed by Vision (e.g., body sees `[12, 14]`, notes see `[12, 13, 14]`), link `12 → 12` and `14 → 14` and skip `13` (a missing link is safe; an invented link is not).
- **Abstention:** If numbers invert, duplicate (e.g., table footnotes colliding with body footnotes), or fewer than half of the page's markers match cleanly, emit **no links on that page**.

No LLM improves this case, and avoiding an LLM keeps same-page linking `$0`, instant, and strictly local.

### 3.2 Backmatter endnotes — deterministic fast path + optional text-only LLM alignment

For a 300-page monograph, pairing marker `7` on page 84 with note `7` on page 273 requires knowing **which body chapter page 84 belongs to** and **which notes block in the backmatter belongs to that chapter**.

1. **Deterministic fast path (try first, `$0`):**
   - Extract chapter boundaries from the PDF `/Outlines` (already read by `SearchableWriter.readOutline`) or from strong typographic chapter openers (display-height heading + `Chapter N` / Roman numeral + marker sequence restarting at `1`).
   - Partition the backmatter Notes section wherever note numbers reset to `1` (corroborated by sub-headings like `Chapter N` or `Notes to Chapter N`).
   - If body block `k` and notes block `k` match by chapter number/title **and** their maximum note number and sequence align cleanly (`max(M_k) ≈ max(N_k)` and ≥85% of markers match monotonically with zero inversions), pair deterministically with no model call.
2. **Where a text-only LLM earns its place:**
   - Real monographs frequently omit `/Outlines` (67 of 78 documents in the Vision OCR corpus had none), use unnumbered chapter titles (`Introduction`, `The Postwar Compact`, `Epilogue`), or format backmatter headers by page range (`Notes to Pages 112–148`, where printed page numbers differ from PDF page indices by frontmatter offset `±14`).
   - A **single text-only call per book** via `ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/LLMTextClient.swift` (which already supports Local Agent CLI → Gateway → Direct provider with a structural no-image boundary, ready to extract into `ArchiveCore` if standalone Vision OCR needs it too) receives only a compact structural digest (~2–6 KB of plain text, `<$0.01`):
     - existing outline entries (if any),
     - candidate chapter-opener lines + page indices + detected marker ranges (`p. 45–78: markers [1..42]`),
     - backmatter note-block headers + page indices + note ranges (`p. 268–272: header "3. Making the Deal", notes [1..42]`).
   - The LLM returns **only** a declarative JSON alignment: `[(bodyStartPage, bodyEndPage, notesStartPage, notesEndPage, confidence)]`.
3. **Mandatory deterministic verifier (the abstention gate):**
   - Whether the chapter-to-notes pairing came from heuristics or the LLM, the **same deterministic verifier** checks every proposed chapter pair:
     - Body markers inside `[bodyStartPage, bodyEndPage]` must be unique and monotonically increasing (allowing missed numbers, forbidding inversions).
     - Matched `(marker_n ↔ note_n)` pairs must cover a strict minimum share (e.g., ≥80% of detected notes in that chapter) and never disagree on chapter count boundaries (e.g., body marker `52` when the notes block ends at `31` immediately rejects the entire chapter mapping).
   - Any chapter that fails verification gets **zero links** and a single calm line in the run log explaining why ("Skipped footnote links for Chapter 4: marker sequence did not match notes block"). Never emit plausible guesses.

---

## 4. Shared PDF link-writing plumbing

### 4.1 Direct reuse of existing qpdf JSON infrastructure

The 2026-08-13 note concluded "do annotation preservation first, because it builds the object-graph plumbing this needs." That plumbing is now built and battle-tested across three files:

1. **`packages/VisionOCRKit/Sources/VisionOCRKit/Annotations.swift`**
   - Proved that `PDFDocument.write(to:)` inflates JBIG2 outputs 1.52×–4.08×, whereas qpdf JSON edits preserve image streams byte-identically.
   - Already implements `Annotations.Document`, inherited-attribute-safe `pageTree(_:)` (`/Rotate`, `/MediaBox`), `maxobjectid` scanning, `append(_:toAnnotsOf:in:nextID:)`, `RunControl.adopting` (FD-safe subprocess lifecycle), and mandatory post-write read-back verification.
2. **`packages/VisionOCRKit/Sources/VisionOCRKit/JBIG2.swift` (`setOutline`)**
   - Even better suited as the exact write template for footnote links: instead of dumping every image stream to disk (`--json-stream-data=file`), `setOutline` runs:
     - `qpdf <file> --json=2 --json-stream-data=none --json-key=pages --json-key=qpdf` (metadata-only read — fast even on 500-page books),
     - builds a minimal patch JSON touching only the affected page dictionaries' `/Annots` arrays plus the new annotation objects numbered past `maxobjectid`,
     - applies it with `qpdf <file> --update-from-json=<patch.json> <out.pdf>`,
     - verifies both the written destinations and untouched page-content fingerprints before atomic replacement.
   - `setOutline` already writes the exact destination array shape needed for footnote links:
     `[ "<targetPageObj> 0 R", "/XYZ", leftOrNull, topY, null ]`.
3. **`ArchiveProcessor/macOS/Sources/ArchiveProcessor/OCR/SearchableArchival.swift`**
   - Already uses `qpdf --update-from-json=... --newline-before-endstream` to finish compressed searchable PDFs as PDF/A-2b. Footnote links on Processor outputs can either append into that same JSON patch (zero extra qpdf pass) or run as a post-assembly qpdf patch pass preserving `--newline-before-endstream`.

### 4.2 Exact PDF annotation object shape

For each verified `(marker, note)` pair, write a `/Link` annotation on the marker's page (and optionally a symmetric back-link on the note's leading number):

```json
{
  "/Type": "/Annot",
  "/Subtype": "/Link",
  "/Rect": [llx, lly, urx, ury],
  "/Border": [0, 0, 0],
  "/F": 4,
  "/P": "12 0 R",
  "/Dest": ["480 0 R", "/XYZ", null, 612.4, null],
  "/NM": "u:archivesuite-fn-v1-p12-n7"
}
```

Key design details:
- **Hit-target padding:** Raw superscript boxes can be ~4×6 pt, which is frustrating to click. Pad `/Rect` outward to a minimum ~10×10 pt target (clamped so it never overlaps an adjacent link).
- **PDF/A-2b compliance (`SearchableArchival`):** Set `/F 4` (`Print` bit on; `Invisible`, `Hidden`, `NoView` off), use direct `/Dest` (no JavaScript or disallowed actions), keep `/Border [0 0 0]`, and pass `--newline-before-endstream`. ISO 19005-2 §6.3.3 exempts `/Link` and `/Popup` from requiring an `/AP` appearance stream when invisible/borderless; verify with a PDF/A validator during implementation.
- **Suite-owned `/NM` prefix (`archivesuite-fn-v1-…`):** Structurally distinguishes Suite-generated links from both reader marks and expired JSTOR/ProQuest wrapper links. If a file is re-linked later, only `archivesuite-fn-*` links are replaced; user highlights and notes are never touched.
- **Interaction with `Annotations.swift` (`transplant` & `anyCopiableMark`):** `copiedSubtypes` deliberately excludes `/Link` (to drop JSTOR/ProQuest wrapper links). That composes cleanly: on a rebuild, `transplant` carries reader marks first (or in the same qpdf JSON edit), and footnote linking appends fresh `archivesuite-fn-*` `/Link` objects afterwards. `anyCopiableMark` continues to ignore `/Link`, so C29 born-digital passthrough is unaffected.
- **Interaction with `ReOCRIncrementalWriter.swift`:**
  - In-place invisible-layer edits (`editLayer` via PDFium) keep the page's `/Annots` dictionary intact, so existing footnote links survive Improve OCR automatically.
  - If Improve OCR ever regenerates links on edited pages, `ReOCRPreservationCheck` would simply allow diffs restricted to `archivesuite-fn-*` `/Link` entries while still enforcing byte-strict preservation of all other annotations.

### 4.3 Archive Reader interaction (important viewer finding)

`ArchiveReader/macOS/Sources/ArchiveReader/Views/PDFPaneView.swift` (`ReaderPDFView`) configures `view.displayMode = .singlePage` and loads a **one-page `PDFDocument` slice** for the currently displayed page (rebuilt per page turn via `.id(pageIdentity)`).

- **Consequence:** Clicking a cross-page `/Link` annotation works out of the box in Preview, Skim, Adobe Acrobat, and iPad/web PDF viewers, and same-page links scroll cleanly everywhere. Inside Archive Reader, however, a `/Dest` pointing at page 273 of the full PDF points at an object outside the 1-page slice PDFKit holds.
- **Clean fix if Reader support is wanted:** Intercept clicks on `/Link` annotations in `ReaderPDFView` (reading the full document's `/Link` destination page index + point), jump via `DocumentViewerModel` to the target page (which automatically pushes the origin onto `pageHistory` so `⌘[` Back returns straight to the body paragraph), and scroll to `targetTopY`. That is a small, bounded Reader follow-up, not a blocker on writing standard PDF links.

### 4.4 Verification bar (matching `Annotations.swift`)

Consistent with `vision-ocr/FEATURES.md` ("a wrong link is worse than no link"):
1. **Structural read-back check (every run):** After `qpdf --update-from-json`, re-read the output PDF via qpdf JSON and assert every written link resolves to a valid in-range page object, `/Rect` lies inside the page's `/MediaBox`, page count and page content fingerprints are unchanged, and existing reader marks are untouched.
2. **Visual & accuracy audit (before shipping):** Render a stratified sample of linked pages with red `/Rect` overlays on markers and blue destination bars on notes, and visually verify (a) hit boxes land on the superscript glyphs and (b) sampled pairs land on the exact intended note with zero cross-chapter mislinks.

---

## 5. Recommendation & Question for the Owner

### What is still unmeasured

Before writing Swift pipeline code, the single decisive unknown from the 2026-08-13 note remains unmeasured: **in your actual scanned monographs and archival print holdings, (1) what fraction have backmatter endnotes vs bottom-of-page footnotes vs neither, and (2) what fraction of tiny superscript markers does Apple Vision `VNRecognizedText.boundingBox(for:)` actually detect cleanly?** (Running that measurement is a small read-only `Tools/` probe over a sample of books — no PDF writes, `$0`.)

### Options for `W50.v2-release`

- **Option 1 (Recommended — Measure first, then decide scope):** In 2.0, build a small `$0` read-only measurement probe (`Tools/probe-footnotes.swift`) that counts footnote/endnote prevalence and measures Vision's per-token superscript recall on a sample of scanned books + archival prints, producing an owner review sheet. Only build the linker once the numbers show Vision sees enough markers to make it genuinely useful.
- **Option 2 (Build same-page footnotes first, `$0` deterministic):** Skip backmatter endnotes for v1; implement `VNRecognizedText.boundingBox(for:)` superscript extraction + deterministic same-page footnote pairing + `qpdf --update-from-json` `/Link` writer (with `/F 4` PDF/A-2b compliance and `/NM` tagging). Zero LLM dependency, zero chapter-alignment risk, works on single archival pages and printed articles as well as books.
- **Option 3 (Target monograph backmatter endnotes directly):** After the small probe, build the full backmatter endnote pipeline (sub-line Vision geometry + deterministic chapter/outline fast path + optional single text-only `LLMTextClient` chapter-alignment call + strict monotonic abstention gate + bidirectional `/Link` annotations + Archive Reader `ReaderPDFView` cross-page click & `⌘[` Back support).
- **Option 4 (Decline / park):** Keep output PDFs free of synthesized links (preserve only reader marks and outlines) and rely on Reader navigation / search.

**Question for the owner:** When `W50.v2-release` opens, which option do you want — **1 (measure first, then pick scope)**, **2 (same-page deterministic footnotes first)**, **3 (full monograph backmatter endnotes + Reader jump)**, or **4 (park/decline)**?
