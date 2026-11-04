# Placement on print, measured: Vision's boxes, aligned readings, three PDF writings on four viewers (W46.place-print)

Gap audit §5 item 21 (`execution-plans/processing-review/10-gap-audit.md`), F-placement tests 2, 3, 5, 6 and 7. Tools:
`ArchiveProcessor/scripts/segbench/place_print.py` (each step's header says how to run it) and
`place_print_report.py`, which writes the tables below and `place-print.json` from the rows in the bench cache
(`~/Library/Caches/ArchiveSuiteRehearsal/place-print/`). No network, no model call, no money.

## Verdict

- **Vision's own layer stays the print route.** `VNRecognizeTextRequest` at `.accurate` (today's layer) beats macOS 26
  `RecognizeDocumentsRequest` on every count: whole-line selection 54.2% against 43.4% of 1,770 typed truth lines
  (−10.8 points, −15.3 to −6.5), Find-placed words −2.4 points (−4.6 to −0.7), and fewer truth lines held whole by one
  line box (83.4% against 75.6%). Its word boxes hold the truth words' centres at F1 0.89 (printed) and 0.92
  (typewritten); at IoU 0.5 F1 is only 0.52-0.59, because Vision's boxes are padded and the truth's are ink-tight, so
  IoU charges padding and not placement. Hands: F1@centre 0.72, and 27% of the truth words on drawn hand lines have no
  Vision box at all, which is W46.place-hands' ground, not this item's.
- **Aligning a better reading onto Vision's lines costs selection nothing and adds a little Find.** The lab's
  `alignedReading` of LightOnOCR-3 4B, Qwen3.6-27B and Gemini 3.8 Flash readings, and of the truth text itself (the
  aligner's ceiling), all tie Vision on whole-line selection (every Δ within ±0.8 points) and place +0.8 to +1.4
  points more of the Find words (the ceiling +1.4, +0.5 to +2.7; the non-drafters' intervals touch 0 on all pages,
  and clear it on the typewritten ones: Qwen +1.4, LightOnOCR +1.6). The selection ceiling is the layer's line
  geometry, not its words: the truth text aligned does no better than Vision's own words.
- **No anchor-share threshold at which a text page wins on placement was found.** By the share of Vision's words a
  reading repeats exactly, the aligned layer places more Find words in every band (sum +243 over 117 page readings)
  and moves whole lines by −9 to +7 a band out of 1,770 a reading. The pages that lose lines are the high-agreement
  ones (0.85-1.00), where the reading changes a word or two on a line; the gain is largest where Vision and the reading
  disagree most. So aligning is the default for print; a text page is kept for what the aligner cannot place
  (hands, W46.place-hands), not chosen by a share threshold on print.
- **The box readers.** PP-OCRv6 det's lines hold 88.2% of the typed truth lines whole and alone, against Vision's
  66.0% and kraken blla's 77.5%, with 2.1% of truth words outside any line (Vision 6.7%). This is the measured case
  for PP-OCRv6 det as the line geometry under a reader on print (gap audit R2), and the reason the paid Gemini
  line-box arm is not run: the open models did not fail. Unlimited-OCR and Nemotron-Parse 2.0 emit blocks
  (paragraphs): 98-99% of truth lines fall whole inside one, but only 9-14% alone, so they serve a block-level
  `replace`, not a line layer; their block text holds 94-95% of the truth words inside the block. GutenOCR-3B
  (cc-by-nc) and Surya-2 (OpenRAIL-M, test only) have no saved readings from any item, and their licences keep them
  out of the app, so they are not scored and no run is filed; granite-docling's DocTags boxes are not scored here.
- **Three writings, four viewers.** On ten typewritten pages the lab's writer and per-word runs come out as whole lines
  in PDFKit, mupdf and pdf.js alike (78-84% of truth lines); OCRmyPDF 17's layer does in PDFKit and mupdf but only
  31.8% in pdf.js (14.8% on the clippings), because pdf.js ends a line between words whose baselines step up a sloped
  line. poppler `pdftotext` is the weak viewer for all three (38-65%), welding a few words a thousand. The PDFKit drag
  is 64-68% strict on typewritten and 39-44% on clippings for all three; the per-word design costs 0.4 MB a page more.
  Nothing here argues for leaving the lab's writer. Acrobat Reader is the owner's check (below).
- **PDF/A.** Once declared PDF/A-2 (the XMP `pdfaid` entries and an sRGB output intent, which the lab writer's PDFs lack
  today), every PDF of every design passes veraPDF 1.30 for PDF/A-2b (50 of 50). For PDF/A-2u, 19 of the 20 `lab`
  PDFs pass, all 15 OCRmyPDF ones, and 11 of the 15 per-word ones. All five failures are one rule, 6.2.11.7.2-1 (a
  glyph with no Unicode mapping), and all five pass once complete ToUnicode maps are added. The lab's one (p024)
  is a font fallback: for symbols Vision misread (★, ₴) Core Text embedded a Hiragino CID font with no map and a
  Helvetica subset whose own map lacks ₴. So PDF/A-2u is within reach of the lab writer: declare it, and write a
  complete ToUnicode map, or keep the invisible layer's text inside the layer font's repertoire.

## Still open

- **The owner's Acrobat Reader check** (F test 5's fifth viewer): five writer pages, each in all three designs under
  blind names, ten Find words and two line drags each, about 20 minutes. Sheet:
  `~/Library/Caches/ArchiveSuiteRehearsal/place-print/acrobat/index.html` (the key is `acrobat-key.json` beside the
  folder, not in it). Gate `W46.place-print-acrobat-owner-ok`; this item is completed once his answers are scored.

<!-- tables -->
## Vision's own word and line boxes against the truth (test 2)

Every audited-ok truth page (owner-typed 40, owner-hand 20, Bentham 14, N6 28). `bywords` is the lab's request (revision 3, `.accurate`, language correction, language detected) with a word per `.byWords` substring, the segmentation the typed truth was drafted from; `accurate` the same request with whitespace words, the words the lab writer lays; `documents` is macOS 26 `RecognizeDocumentsRequest`. F1 is one-to-one over word boxes; the truth boxes are ink-tight and Vision's padded, so @centre (each box holds the other's centre) is the figure that does not charge padding. Recall and no-box by the truth line's source: `drawn` lines were drawn by subagents, `Vision` lines drafted from Vision's own (OCR-10); the drawn ones are the hard pages, so the two are not a like comparison. Bentham and N6 have line geometry only.

| group | kind | API | pages | truth words | F1@0.5 | F1@0.7 | F1@centre | recall@centre, Vision lines | recall@centre, drawn lines | no Vision box, Vision lines | no Vision box, drawn lines | baseline F |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| owner-typed | printed | bywords | 14 | 6752 | 0.582 | 0.147 | 0.890 | 93.9 | 76.5 | 1.7 | 17.1 | 0.887 |
| owner-typed | printed | accurate | 14 | 6752 | 0.585 | 0.148 | 0.894 | 93.9 | 76.9 | 1.7 | 16.7 | 0.887 |
| owner-typed | printed | documents | 14 | 6752 | 0.540 | 0.113 | 0.886 | 93.7 | 72.3 | 2.3 | 21.2 | 0.865 |
| owner-typed | typewritten | bywords | 26 | 7355 | 0.520 | 0.117 | 0.911 | 97.9 | 75.9 | 1.4 | 19.1 | 0.908 |
| owner-typed | typewritten | accurate | 26 | 7355 | 0.520 | 0.118 | 0.915 | 97.9 | 77.0 | 1.4 | 17.7 | 0.908 |
| owner-typed | typewritten | documents | 26 | 7355 | 0.511 | 0.102 | 0.905 | 97.7 | 73.2 | 1.3 | 22.3 | 0.901 |
| owner-hand | handwritten | bywords | 18 | 2715 | 0.346 | 0.109 | 0.723 | — | 62.5 | — | 28.6 | 0.741 |
| owner-hand | handwritten | accurate | 18 | 2715 | 0.345 | 0.108 | 0.727 | — | 63.4 | — | 27.4 | 0.741 |
| owner-hand | handwritten | documents | 18 | 2715 | 0.323 | 0.099 | 0.669 | — | 54.3 | — | 38.2 | 0.648 |
| owner-hand | mixed | bywords | 2 | 217 | 0.427 | 0.074 | 0.872 | — | 86.6 | — | 5.1 | 0.852 |
| owner-hand | mixed | accurate | 2 | 217 | 0.435 | 0.075 | 0.888 | — | 87.6 | — | 3.2 | 0.852 |
| owner-hand | mixed | documents | 2 | 217 | 0.498 | 0.110 | 0.909 | — | 87.6 | — | 5.1 | 0.882 |
| L2-bentham | handwritten | bywords | 14 | 0 | — | — | — | — | — | — | — | 0.804 |
| L2-bentham | handwritten | accurate | 14 | 0 | — | — | — | — | — | — | — | 0.804 |
| L2-bentham | handwritten | documents | 14 | 0 | — | — | — | — | — | — | — | 0.775 |
| N6 | print | bywords | 28 | 0 | — | — | — | — | — | — | — | 0.833 |
| N6 | print | accurate | 28 | 0 | — | — | — | — | — | — | — | 0.833 |
| N6 | print | documents | 28 | 0 | — | — | — | — | — | — | — | 0.899 |
## The line pass, Find and the aligner (test 3)

The 40 owner-typed truth pages, every folded truth line of two or more scored words (owner rulings folded, W46.place-lines-owner-ok). Each arm's layer is the lab writer's (SearchableWriter.compose, one level run per line) over Vision's line boxes; an aligned arm's text is the lab's own `alignedReading` of the saved reading onto Vision's `accurate` lines. `strict` is PDFKit's drag returning exactly the layer's words for the line; `loose` the same selection with case and punctuation aside (a dropped closing comma passes). A line the layer holds no word for fails. Δ is against Vision's own layer on the pages both have, paired over pages. Gemini 3.8 Flash and Qwen3.6-27B have no usable reading of 2 and 1 pages; their rows are on the pages they read.

### all pages

| arm | pages | lines | strict pass % | Δ strict vs Vision (95% CI) | loose pass % | strict, Vision lines | strict, drawn lines | Find % | Find placed % | Δ placed vs Vision (95% CI) | word F1@centre |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---:|
| Vision's own lines (VNRecognizeTextRequest, today's layer) | 40 | 1770 | 54.2 | — | 61.4 | 67.9 | 38.0 | 91.8 | 89.0 | — | 0.763 |
| Vision's RecognizeDocumentsRequest lines | 40 | 1770 | 43.4 | -10.8 (-15.3 to -6.5) | 53.3 | 55.9 | 28.6 | 90.2 | 86.6 | -2.4 (-4.6 to -0.7) | 0.783 |
| truth text aligned onto Vision (the aligner's ceiling) | 40 | 1770 | 53.9 | -0.3 (-0.9 to +0.4) | 61.1 | 67.2 | 38.1 | 93.4 | 90.4 | +1.4 (+0.5 to +2.7) | 0.741 |
| Gemini 3.8 Flash aligned (drafted the truth text) | 38 | 1671 | 54.0 | -0.6 (-1.0 to -0.2) | 61.3 | 66.4 | 38.8 | 93.8 | 90.9 | +1.3 (+0.3 to +2.7) | 0.742 |
| Qwen3.6-27B aligned (non-drafter) | 39 | 1754 | 54.3 | +0.1 (-0.3 to +0.6) | 61.3 | 67.8 | 37.9 | 93.1 | 90.2 | +1.0 (-0.1 to +2.2) | 0.754 |
| LightOnOCR-3 4B aligned (non-drafter) | 40 | 1770 | 54.4 | +0.1 (-0.4 to +0.7) | 61.3 | 67.9 | 38.2 | 92.6 | 89.8 | +0.8 (-0.3 to +2.2) | 0.761 |

### typewritten pages

| arm | pages | lines | strict pass % | Δ strict vs Vision (95% CI) | loose pass % | strict, Vision lines | strict, drawn lines | Find % | Find placed % | Δ placed vs Vision (95% CI) | word F1@centre |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---:|
| Vision's own lines (VNRecognizeTextRequest, today's layer) | 26 | 794 | 63.9 | — | 71.0 | 77.0 | 49.3 | 90.7 | 88.3 | — | 0.737 |
| Vision's RecognizeDocumentsRequest lines | 26 | 794 | 51.8 | -12.1 (-16.8 to -7.3) | 63.6 | 64.3 | 37.9 | 89.2 | 85.8 | -2.5 (-5.2 to -0.2) | 0.765 |
| truth text aligned onto Vision (the aligner's ceiling) | 26 | 794 | 63.4 | -0.5 (-1.0 to +0.0) | 70.8 | 76.5 | 48.8 | 92.7 | 90.1 | +1.8 (+0.8 to +3.2) | 0.723 |
| Gemini 3.8 Flash aligned (drafted the truth text) | 26 | 794 | 63.5 | -0.4 (-0.9 to +0.3) | 70.8 | 76.5 | 49.1 | 92.7 | 90.1 | +1.8 (+0.6 to +3.3) | 0.723 |
| Qwen3.6-27B aligned (non-drafter) | 25 | 778 | 63.6 | -0.3 (-0.9 to +0.5) | 71.0 | 76.7 | 48.5 | 92.7 | 90.1 | +1.4 (+0.2 to +2.9) | 0.723 |
| LightOnOCR-3 4B aligned (non-drafter) | 26 | 794 | 63.7 | -0.1 (-0.7 to +0.5) | 70.9 | 77.0 | 49.1 | 92.2 | 89.9 | +1.6 (+0.5 to +3.3) | 0.736 |

### printed pages

| arm | pages | lines | strict pass % | Δ strict vs Vision (95% CI) | loose pass % | strict, Vision lines | strict, drawn lines | Find % | Find placed % | Δ placed vs Vision (95% CI) | word F1@centre |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|---|---:|
| Vision's own lines (VNRecognizeTextRequest, today's layer) | 14 | 976 | 46.4 | — | 53.6 | 60.9 | 28.1 | 93.0 | 89.7 | — | 0.791 |
| Vision's RecognizeDocumentsRequest lines | 14 | 976 | 36.7 | -9.7 (-16.4 to -2.8) | 45.0 | 49.5 | 20.4 | 91.3 | 87.4 | -2.3 (-5.8 to +0.1) | 0.802 |
| truth text aligned onto Vision (the aligner's ceiling) | 14 | 976 | 46.2 | -0.2 (-1.0 to +1.2) | 53.2 | 60.0 | 28.8 | 94.3 | 90.7 | +1.0 (-0.2 to +3.4) | 0.761 |
| Gemini 3.8 Flash aligned (drafted the truth text) | 12 | 877 | 45.5 | -0.8 (-1.3 to -0.3) | 52.7 | 58.1 | 28.4 | 95.1 | 91.8 | +0.8 (-0.5 to +3.3) | 0.765 |
| Qwen3.6-27B aligned (non-drafter) | 14 | 976 | 46.8 | +0.4 (+0.0 to +1.2) | 53.7 | 60.9 | 29.0 | 93.5 | 90.2 | +0.5 (-0.9 to +2.8) | 0.787 |
| LightOnOCR-3 4B aligned (non-drafter) | 14 | 976 | 46.7 | +0.3 (-0.3 to +1.4) | 53.5 | 60.9 | 28.8 | 93.0 | 89.6 | -0.1 (-1.6 to +2.1) | 0.788 |

### When does aligning stop paying? Aligned against Vision's own layer, by anchor share

Per page and reading (the three saved readings): the share of Vision's words the reading pairs with an equal word (an approximation of the lab's anchors, which it does not report), and the change in Find-placed words and in strictly passing lines against Vision's own layer. The lab keeps Vision's words when under half of them are its anchors; its anchors match loosely (wordLikeness), so this exact-equality share is lower than the lab's and pages under 0.50 here were still rewritten. A text page leaves Vision's layer as it is and adds the reading on a page of its own: it never costs placement, and it adds Find for the reading's words that the layer lacks.

| anchor share | page readings | lines rewritten | Δ placed words (sum) | pages placed worse | Δ passing lines (sum) | pages losing lines |
|---|---:|---:|---:|---:|---:|---:|
| 0.00–0.50 | 13 | 139 | +119 | 1 | +3 | 1 |
| 0.50–0.70 | 8 | 80 | +7 | 1 | +7 | 0 |
| 0.70–0.85 | 11 | 149 | +1 | 2 | +0 | 0 |
| 0.85–0.95 | 32 | 344 | +83 | 9 | -7 | 7 |
| 0.95–1.00 | 53 | 401 | +33 | 11 | -9 | 11 |

## Three writings of the same words, four viewers (test 5)

Ten typewritten pages (every second non-clipping one in page order) and the five clippings (p072, p078, p080, p081, p098), Vision's `accurate` words and lines written three ways, each over the page image: `lab`, the Vision OCR lab's SearchableWriter (one run per line, the font sized to fit, a 0.25 em reserve); `ocrmypdf`, OCRmyPDF 17.13's own `hocrtransform` over the same words as hOCR (one BT block a line, per-word Tz, a trailing space, its glyphless Occulta font, the line's baseline slope); `words`, every word its own text object with a real trailing space and no reserve (Helvetica, Tz to the box). PDFKit is the drag and Find; for every viewer, its text extraction: `line` a truth line whose expected words come out adjacent and in order inside one extracted line, `welded` extracted tokens that are two or three layer words run together, `split` layer words that come out in two pieces. Extractions: PDFKit `page.string`, poppler 26 `pdftotext`, mupdf 1.28 `mutool draw -F txt`, pdf.js 6.5 `getTextContent` (a line ends at an item marked hasEOL).

### ten typewritten pages

| design | lines | PDFKit drag strict % | loose % | Find placed % | PDFKit line % | poppler line % | mupdf line % | pdf.js line % | welded per 1,000 words (PDFKit/poppler/mupdf/pdf.js) | split per 1,000 | MB a page |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| lab | 327 | 64.5 | 70.3 | 79.2 | 83.2 | 65.4 | 80.4 | 83.2 | 0.8 / 4.1 / 0.0 / 0.8 | 0.0 / 0.0 / 0.0 / 0.0 | 1.64 |
| ocrmypdf | 327 | 63.9 | 70.9 | 79.3 | 82.0 | 64.8 | 80.1 | 31.8 | 0.0 / 3.8 / 0.0 / 7.5 | 0.0 / 0.0 / 0.0 / 0.0 | 1.63 |
| words | 327 | 67.9 | 73.7 | 79.3 | 84.1 | 58.7 | 79.8 | 78.9 | 0.0 / 5.3 / 0.0 / 5.6 | 0.0 / 0.0 / 0.0 / 0.0 | 2.03 |

### the five clippings

| design | lines | PDFKit drag strict % | loose % | Find placed % | PDFKit line % | poppler line % | mupdf line % | pdf.js line % | welded per 1,000 words (PDFKit/poppler/mupdf/pdf.js) | split per 1,000 | MB a page |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---:|
| lab | 519 | 39.1 | 44.3 | 87.2 | 82.9 | 65.3 | 81.3 | 83.0 | 1.0 / 8.5 / 0.0 / 1.0 | 0.0 / 0.0 / 0.0 / 0.0 | 1.40 |
| ocrmypdf | 519 | 43.9 | 49.3 | 87.4 | 80.9 | 38.2 | 81.5 | 14.8 | 0.0 / 9.2 / 0.0 / 10.8 | 0.0 / 0.3 / 0.0 / 0.0 | 1.40 |
| words | 519 | 43.4 | 48.4 | 88.0 | 82.7 | 48.4 | 81.1 | 78.0 | 0.0 / 11.2 / 0.0 / 10.2 | 0.0 / 0.0 / 0.0 / 0.0 | 1.75 |

## PDF/A (test 6)

veraPDF 1.30 over each PDF made a PDF/A-2 candidate (XMP `pdfaid` part 2, conformance B or U, and an sRGB output intent; nothing else changed), so what it finds is the file's own content: its fonts, their embedding and their Unicode mapping. Twenty `lab` PDFs (the fifteen writer pages and five more typewritten ones) and the fifteen of each other design. The same files without the declarations fail (6.6.2.1 metadata, 6.2.4.3 DeviceRGB without an output intent), so the validator is reading them. Where 2u fails, every font is given a full ToUnicode map (`add_to_unicode`): a simple font's from its encoding (ZapfDingbats and Symbol by their built-in ones), a Core Text TrueType subset's rebuilt from its embedded cmap's glyph names through the installed font (Core Text's own map can miss a glyph), and an Identity-H CID fallback font's from its CFF charset through the installed font; the extracted text is unchanged by it.

| design | PDFs | PDF/A-2b compliant | PDF/A-2u compliant | 2u after adding ToUnicode maps | rules failed |
|---|---:|---:|---:|---:|---|
| lab | 20 | 20 | 19 | 1 of 1 | 6.2.11.7.2-1 |
| ocrmypdf | 15 | 15 | 15 | not needed | none |
| words | 15 | 15 | 11 | 4 of 4 | 6.2.11.7.2-1 |

## Acrobat Reader, the owner's check (test 5, fifth viewer)

Not answered yet: the sheet is `acrobat/index.html` in the bench cache, gate `W46.place-print-acrobat-owner-ok`.

## The box-emitting readers and the open detectors beside Vision (test 7)

The 40 owner-typed pages, the same folded truth lines. A truth line is `whole` when one region holds the centres of all its scored words, `whole and alone` when that region holds no other truth line's word as well (what a line run needs); `outside` truth words lie in no region. blla (kraken 7.1.1) and PP-OCRv6 det lines are W46.fix-place-truth-lines' (polygons where saved); Unlimited-OCR and Nemotron-Parse 2.0 blocks are W46.ocr-new-open-boxes' Sherlock records, reversed or zero-area boxes left out, not repaired. For the blocks, `in block text` is the share of the truth words inside a block that the block's own text holds (what a block-level `replace` would put there). Nemotron's canvas transform is rebuilt (centred padding), checked against Unlimited's blocks of like text: 335 pairs, median offset (+0.0012, -0.0012) of the page, 319 within 0.02 of the page on both axes.

| source | pages | regions | truth lines | whole % | whole and alone % | truth words outside % | baseline F | in block text % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| vision-accurate | 40 | 2099 | 1770 | 83.4 | 66.0 | 6.7 | 0.901 | — |
| vision-documents | 40 | 2193 | 1770 | 75.6 | 57.7 | 7.9 | 0.889 | — |
| blla | 40 | 2036 | 1770 | 82.9 | 77.5 | 11.0 | 0.797 | — |
| ppocrv6 | 40 | 2080 | 1770 | 94.2 | 88.2 | 2.1 | 0.933 | — |
| unlimited-ocr | 39 | 553 | 1690 | 99.0 | 13.5 | 0.2 | — | 93.6 |
| nemotron-parse-2 | 40 | 501 | 1770 | 98.4 | 9.4 | 0.6 | — | 94.5 |

<!-- /tables -->

## Measurement card

- **Truth.**
  - The placement truth (`place-truth.md`): the 40 owner-typed pages (14 printed, 26 typewritten) and the 20
    owner-hand pages of the 96, with W46.place-lines-owner-ok's rulings folded into the typed lines
    (`place_geom.fold_lines`: merges where the owner read one line; the three tables he said break at more places
    than the sheet marked left out). The typed truth's text was drafted from Gemini 3.8 Flash's reading and checked
    by the owner, so Gemini's aligned row is labelled the drafter and the two non-drafters carry the comparison.
  - Typed word boxes were drafted from Vision's `.byWords` tokens and trimmed to the ink; typed lines are 51% drafted
    from Vision's lines and 49% drawn by Claude subagents (`place-truth-lines.md`). Both favour Vision: every
    Vision row is reported apart on Vision-derived and on drawn lines (OCR-10), and the drawn lines, the harder
    pages, are about 30 points lower for every arm alike. The aligned arms sit on Vision's lines, so the favour is
    shared, and the comparison between them is not affected.
  - Bentham (14) and N6 (28) public pages have line geometry only: Vision's baseline F is reported there, no word
    or selection score.
- **Selection.** Every audited-ok placement-truth page; no route chose a page. The writer pages: every second
  non-clipping typewritten page in page order, plus the five clippings; the veraPDF extras the next five by the same
  rule; the Acrobat pages three of the writer pages and two clippings, fixed in the script. No ABBYY text was used.
- **Comparison.** One saved Vision reading per page and API; every aligned arm uses the same Vision lines, the lab's
  own aligner and writer, the same PDFKit drag from each truth line's first ink to its last, and the same scored line
  set (truth lines of two or more scored words, under 45° off level). The writers lay the same Vision words.
  Both OCR sets: the 895-page public set has no word or selection truth; Bentham and N6, its only sets with line
  geometry, are scored for line boxes. The saved readings are the ones `ocr_rescore.owner_sources()` holds for the
  96; Gemini 3.8 Flash lacks a usable reading for 2 pages and Qwen3.6-27B for 1, and their rows are paired on the
  pages they read.
- **Noise.** n = 40 typed pages and 1,770 scored lines (writers: 10 + 5 pages, 327 + 519 lines). Intervals are paired
  bootstrap over pages (2,000 draws, 95%); a Δ whose interval holds 0 is a tie. Every step is deterministic (saved
  readings, no sampling): three pages of test 3 (p002, p057, p080, all six arms) rerun on 2026-11-03 reproduced every
  stored row exactly, so the rerun floor is 0 and the page sample is the noise. The writers' table has no interval:
  its 10 + 5 pages are a viewer check, and only gaps of several points are read from it.
- **Scope.** Print only (hands are W46.place-hands and W46.place-hands-lines). PDFKit is the only drag; poppler,
  mupdf and pdf.js are scored by their text extraction, which is what their selection and copy return, not by a
  pointer drag. A real user's drag varies more than one from first ink to last. The anchor share is an exact-equality
  approximation of the lab's anchors, which it does not report. It does not settle Acrobat Reader (the owner's check),
  the straightened reading copy (W46.place-geom), or why 46% of the typed lines fail on Vision's own layer, which is the
  line geometry: Vision's line boxes join or split a truth line (34% of lines are not held whole and alone by one Vision
  line), and PP-OCRv6 det's lines are the measured candidate for that.
