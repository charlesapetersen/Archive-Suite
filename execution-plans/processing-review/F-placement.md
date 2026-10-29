# Strand F deep read: placing OCR text on the page image

Written 2026-10-20 from full reads of the sources named below. Tags: [M] measured or stated in the source at the
location given; [I] my inference from a source; [?] not verified. "Code read" means the file itself was read, not
its README. Screen: `F-screen.md`. Strand D's note (`D-enhancement.md`) settles the dewarp-grid half of question 5
and is cited, not repeated.

Reads against the screen's shortlist, and why:
- Kept: kraken's forced alignment (both `kraken/align.py` and the current `kraken/tasks/align.py`, code read), the
  Bullinger CTC alignment paper (arXiv 2508.07904, full HTML), GutenOCR (arXiv 2601.14490, full HTML, plus its HF
  cards), Orli (arXiv 2606.04166, full HTML, plus its GitHub record), READ-BAD (arXiv 1705.03311, PDF pages 1-6),
  OCRmyPDF (the fpdf2 renderer's source, its font provider and PDF/A module, and the advanced-features docs), and
  Apple's documentation JSON for `boundingBox(for:)`, `RecognizedTextObservation`, `DocumentObservation` and its
  `Container.Text` (words, lines, transcript).
- local-llm-pdf-ocr was not re-read: GitHub's commit list shows no commit after `9b3ca2e` (2026-09-19), the commit
  `PRIOR-ART-2026-10-05.md` §4 was checked against, so that section is current [M GitHub API].
- Dropped to the screen's reading: the OCR-D dewarping note (strand D read it and settled the point), Surya's card
  (only its README's output schema was checked), PLATTER (GutenOCR supplies the same F1@IoU template with more
  detail), Transkribus Text2Image (the Bullinger paper documents its failure mode at first hand).
- Added, because they answer questions the screen left open: veraPDF's validation profiles (the machine-readable
  form of the PDF/A-2 and PDF/UA-1 rules on fonts, ToUnicode and artifacts), pdf.js's `text_layer.js`, the Azure,
  Textract and Document AI geometry pages, and three measurements of our own the screen did not know about:
  `HW-PLACE-2026-10-15.tsv`, `HW-COVERAGE-2026-10-15.tsv` and `HW-PANEL-2026-10-15.tsv` in the Vision OCR lab, which
  already answer "can align place a VLM's handwriting?" on the owner's truth pages.

## 1. Question

How to put a reader's text on the page image as an invisible, selectable, searchable layer whose words sit on their
ink, for each user profile and each kind of page: where the positions come from (the reader, Apple Vision, a line
detector, or a forced alignment), how to score placement on our own pages, what to do when a position-free model's
text and a detector's lines disagree, which image carries the layer after dewarping, how Preview, PDF.js and Acrobat
treat such a layer and what PDF/A and PDF/UA require of it, and when the separate text page the Processor writes
today is still the right output.

## 2. What the field does now

Every production tool that writes a searchable layer does the same four things: a detector or recogniser supplies a
box per word or per line, text is drawn in rendering mode 3 (invisible) over the image, the drawn width of each run
is made to match its box, and the viewer is left to re-derive word boundaries from geometry. The tools differ only in
the unit and the knob. Tesseract and OCRmyPDF draw one show-op per word, with a real space after every non-last word,
and fit the width with horizontal scaling (`Tz`) over a glyphless fixed-pitch font (Tesseract's GlyphLessFont,
OCRmyPDF's `Occulta.ttf`); OCRmyPDF's current renderer keeps all words of a line in one BT block with per-word `Tz`
because poppler does not carry `Tz` across BT/ET boundaries [M renderer.py 751-770]. Our Vision OCR writer draws one
run per Vision line in Helvetica and fits the width by font size, squashing height in the text matrix, with a
deliberate 0.25 em reserve before the next fragment on the line [M SearchableWriter.swift 17-98]. Azure Document
Intelligence now writes the layer itself for its `prebuilt-read` model at no extra cost [M Azure docs].

Positions come from one of three places. Classical OCR (Tesseract, PP-OCR, kraken, Apple Vision, Surya's detector,
the cloud OCR services) detects first and so has a box per line and usually per word. The 2025-26 document VLMs
mostly return text without positions (olmOCR-2, Falcon-OCR, the Qwen and Gemma chat models, every subscription CLI);
a minority emit boxes by prompt, almost always at block or line level (Surya-2, Unlimited-OCR, Nemotron-Parse,
dots.ocr, LightOnOCR-3's `grounding`, Qwen3-VL grounding), and one fine-tune, GutenOCR, is trained to emit line and
word boxes and reports detection F1 for them. The third source is alignment: a known transcript is placed onto
detected lines by dynamic programming, either over character counts (local-llm-pdf-ocr; Vision OCR's `alignedReading`
aligns on Vision's own words instead) or over a CTC recogniser's posteriors (kraken's forced alignment, the Bullinger
method), which is how the humanities HTR world builds line-level training data from letter-level transcriptions.

Evaluation of placement is thin everywhere. Line detection has an accepted metric, the cBAD/READ-BAD coverage-based
R, P and F over baselines with a per-line tolerance (2017), and a 2026 state of the art near F 0.935 on cBAD 2019
(Orli). Word boxes are scored with detection F1 at IoU 0.5 when they are scored at all (GutenOCR). Nobody publishes a
metric for the thing the user feels, whether Find highlights the right ink and whether a drag selects whole words
and lines; the only controlled measurements of PDFKit's behaviour over an OCR layer that I know of are the Vision OCR
lab's own instruments (`RESEARCH-2026-08-16.md` §4). Handwriting placement is the open end: Apple Vision finds
handwritten lines partially, the position-emitting VLMs are trained on print (GutenOCR's recall on OmniDocBench's
handwritten notes is 0.000), and the HTR tools that can align handwriting need a trained CTC model per script.

## 3. Claims table

| Source | Claim | Figure | Conditions | Tag | Location |
|---|---|---|---|---|---|
| Apple, `VNRecognizedText.boundingBox(for:)` | At `.accurate` the box "has word precision": a range inside a word returns the box of the whole word containing the first character; at `.fast` it has character precision | | "Bounding boxes aren't always an exact fit around the characters... avoid using their contents for image processing" | [M] | doc JSON, discussion; macOS 10.15+ |
| Apple, `RecognizedTextObservation` (macOS 15+) | Per line: `boundingRegion` polygon, `transcript`, `topCandidates`, `shouldWrapToNextLine`, `textDirection`, `isTitle` | | | [M] | doc JSON topics |
| Apple, `RecognizeDocumentsRequest` / `DocumentObservation.Container.Text` (macOS 26) | `words: [RecognizedTextObservation]?`, `lines`, `paragraphs`, `boundingRegion` polygon, `boundingRegion(for:)`; "Chinese, Japanese, Korean, and Thai don't recognize individual words" | | New in the 26 generation; no accuracy figures | [M] | doc JSON for `Text`, `words` |
| Vision OCR, `vision_words.swift` (ours) | Word boxes for all 100 truth pages were taken with `VNRecognizeTextRequest` at `.accurate` through `boundingBox(for:)` per `.byWords` range; 2.7 MB `vision-words.json` | 100 pages | | [M] | `~/Library/Caches/ArchiveSuiteRehearsal/ocr-truth/review-tools/vision_words.swift` |
| Vision OCR, `SearchableWriter` (ours) | One run per Vision line, Helvetica, `setTextDrawingMode(.invisible)`; width fitted by font size, height by a text-matrix squash; `baselineFraction` 0.22 (median offset 0.00, worst 0.20 over 78 documents); `headroomFactor` 0.95 to 1.5 took line-by-line selection from 80-83% to 84-91% on 1920s-50s letters and 100% on modern print; `reserveEms` 0.25 inside the (0.15, 0.30) window; `minimumVertical` 0.5 to 0.25 took worst-case line-end selectability 71% to 91% (28 documents better, 1 worse, 84-document corpus) | | PDFKit, the lab's 233-document corpus | [M] | `Sources/SearchableWriter.swift` 24-127, 324 |
| Vision OCR, `RESEARCH-2026-08-16.md` | Extractors insert a space from geometry: poppler word break at 0.1 em, pdf.js tracking space at 0.102 em, mupdf at 0.15 em (mupdf alone honours a real `U+0020`); PDFKit's threshold is unknown upstream and measured by us near 0.15 em; Tesseract's per-word runs with real spaces still "mightrunseveralwordstogether" in Preview per OCRmyPDF | | Quoted from upstream source | [M] | §1, §2 |
| Vision OCR, `Recogniser.alignedReading` (ours) | A model's words go onto Vision's lines by monotonic word-level edit alignment: anchor likeness 0.5, gap cost 0.7, at most 3 unanchored insertions between two anchors on one line, a line rewritten only when at least half its words are anchors, the page kept as Vision read it when under half of all Vision words are anchors; hyphenated line-end words joined for alignment and split where Vision split them; 64M-cell cap | | | [M] | `Sources/Recogniser.swift` 1706-1917 |
| Vision OCR, `OCR-COMPARE-2026-10-13` (ours) | Falcon-OCR through align on 56 print pages: 0.63% words wrong or missing against Vision's 1.20%, Find 0.993 against 0.989, Copy 0.034; better on 25 pages, worse on 5 | 56 pages, 25,414 words | The layer keeps Vision's placement; the model only mends words | [M] | §1 |
| Vision OCR, `HW-PLACE-2026-10-15.tsv` (ours) | Align places 65% of LightOnOCR-3-4B's handwriting words (placed 0.654, kept 0.708); handwriting missed per 1,000 goes 96 as read to 367 through align; Qwen3.5-9B 91 to 365; Find finds 922 of 1,405 distinct truth words in the align PDFs against 585 in Vision's own; pages Vision barely found keep almost nothing (p094 7%, p096 16%). Decision: handwritten pages get a text page | 21 pages (19 handwritten, 2 mixed) of the owner's truth set | Through the app's own route | [M] | header and ALL rows |
| Vision OCR, `HW-COVERAGE-2026-10-15.tsv` (ours) | Vision's lines cover 392 of 503 handwritten text lines (78%), 64 partial, 47 missed; about 82% of words inside a box; worst p094 25% (motion blur), p050 45%, p054 50% | 21 pages | Counted by eye over Vision's boxes, not measured; the ink-share measure was judged unusable | [M that it is an estimate] | header, rows |
| Vision OCR, `HW-PANEL-2026-10-15.tsv` (ours) | kraken PP-OCRv6 medium reading Vision's line boxes on handwriting: 666 missed per 1,000, worse than Vision's 561 on the same lines; 2.7 s a page; 3.8 GB a process; kraken's own `blla` segmenter not run | 21 pages | | [M] | header lines 3, 12-13; notes `hw-qwen.md` |
| Vision OCR, `HW-BUILD-2026-10-15` via `hw-qwen.md` | With the text page on, 19 of 21 pages got one; 99 missed per 1,000 on them; Find 1,238 of 1,405 (align 922) | | | [M] | `ops/autonomous/notes/hw-qwen.md` session 2 |
| Processor, `PDFGenerator.makeImagePage` (ours) | Page 1 embeds the JPEG bytes verbatim (or re-encodes) and draws no text | | | [M] | `OCR/PDFGenerator.swift` 79-135 |
| Processor, truth set | Truth transcripts are one whole-page line with no line breaks (`truth/p007.txt` is 1 line); 416 disputed spans were located on the page by aligning each model's reading to Vision's words (`locate.py`) | 99 truth files | | [M] | cache `truth/`, `review-tools/locate.py` |
| Processor, public set README | 15 strata, 895 pages; N6 Devanagari print comes as "full-page ALTO/PAGE pairs"; L8 is OCR-D `gt_structure_text`; images and truth are private, scores public | | Whether other strata carry line geometry is not stated | [M]; geometry of other strata [?] | `segbench-results/bench-corpus/README.md` table |
| local-llm-pdf-ocr | Expected characters per box = area share x page characters; overfill cost (actual-expected)/actual, underfill x0.5; skip line 1.0, skip box 0.4; tries row-major and column-major orders; per-box fallback when 8+ boxes and under half matched; text stretched to 98% of box width; no commits after 2026-09-19 | | Thin evaluation (15 history rows) | [M] | `PRIOR-ART-2026-10-05.md` §4 at 9b3ca2e; GitHub commits API |
| Bullinger CTC alignment (arXiv 2508.07904, CC BY 4.0) | DP over CTC character posteriors with ε-compression (θ 0.99) places a letter-level transcript onto line images; the transcript is never changed and no word may be skipped, but gaps are allowed by inserting several newlines; returns a confidence γ6 over the first and last six characters | | Code and 100 corrected pages at github.com/andreas-fischer-unifr/nntp | [M] | §3.3 |
| Bullinger | Line-level alignment accuracy: HTRFlor 86.1 / 79.7, PyLaia 86.1 / 77.3, Retsinas 81.5 / 73.0 (Subset 1 / 2) | 100 pages, 2,388 lines | 16th-century Latin and German letters | [M] | Table 4, Table 1 |
| Bullinger | A weakly trained model (15 epochs) aligns better than the converged one: 88.5 vs 86.1 (Subset 1), 89.1 vs 77.3 (Subset 2); fine-tuning on aligned data gains 1.1 CER points (PyLaia); 2.28-3.54 s to align a letter of 34.6 lines | | | [M] | §5.2-5.3, Table 5 |
| Bullinger | The dataset's errors come from Transkribus's automatic alignment and are "mainly caused by hyphenations at the beginning and end of lines" | | | [M] | §1, §3.1 |
| kraken `tasks/align.py` (Apache-2.0) | `ForcedAlignmentTaskModel.predict` aligns a given transcription to a recognition model's output, "producing approximate character locations", returned as cuts (start, end) scaled to the line image's width; the legacy path skips a line whose output has fewer than 2x the label count of frames | | Needs a kraken recognition model whose alphabet covers the text | [M] | `tasks/align.py` 30-133; `align.py` 60-66 |
| Orli (arXiv 2606.04166; code Apache-2.0) | cBAD 2019: high-res base P 0.9378 R 0.9302 F1 0.9340, coverage 0.9406, zero-shot; fine-tuned F1 0.9351; previous best Planet 0.931; low-res base F1 0.7533 | | Input 1920x1440; ConvNeXtV2-tiny backbone, RT-DETR hybrid encoder, autoregressive decoder; 196,691 training pages; 3 A40s about 32 h; parameter count not stated | [M] | Table 3, §3.5, §5.2; licence from GitHub API |
| Orli | Reading order OHG zero-shot: footrule 0.0033, Kendall τ 0.9967, coverage 0.9993 (FDTD 0.0069 / 0.9913; top-bottom-left-right 0.0291 / 0.9667) | | Scores on matched lines only | [M] | Table 4 |
| READ-BAD (arXiv 1705.03311) | 2036 pages, 132,124 baselines; tolerance per GT baseline t = 0.25 x min(distance to nearest baseline, page mean), default 250 when alone; a vertex within t counts 1, falling linearly to 0 at 3t; R = mean coverage of GT chains, P after greedy one-to-one alignment, F harmonic; needs no binarisation and handles skew; Java tool LGPLv3 | Baseline system Simple F 0.912, Complex 0.728 | | [M] | pp. 3-6, Alg. 1-2, Table III |
| GutenOCR (arXiv 2601.14490) | Qwen2.5-VL-3B/7B fine-tunes emit axis-aligned pixel boxes for lines, paragraphs and (card) words by prompt; in-domain detection F1@0.5 0.798 (3B) and 0.787 (7B) against backbones 0.135 and 0.111; conditional detection 0.877 / 0.882; lines CERe2e 0.185 / 0.147; composite 0.348 to 0.811 and 0.396 to 0.819 | 10.5K held-out business and scientific pages | Boxes are axis-aligned; "we do not predict rotated boxes" | [M] | Table 6, §2.2; card `WORDS` mode line 188 |
| GutenOCR | OmniDocBench text-detection recall@0.5: 0.620 (3B), 0.549 (7B); handwritten Notes 0.000 for every model including GutenOCR; page CER 0.138 against the backbone's 0.051 | | Recall only; incomplete annotations | [M] | Table 10, §5.3 |
| GutenOCR weights | `bevaya/GutenOCR-3B` 4.07B params, `-7B` 8.29B; licence cc-by-nc-4.0 | | GGUF ports exist (mradermacher, prithivMLmods) | [M] | HF API |
| OCRmyPDF fpdf2 renderer (MPL-2.0) | One BT block per line, `3 Tr`, per-word `Tz` so that "word " spans to the next word's start; fonts: bundled NotoSans and glyphless `Occulta.ttf` fallback; rotated and sloped baselines through `cm`; ligature shaping off for invisible text because Ghostscript 10.05-10.06 drop multi-character ToUnicode entries in PDF/A conversion (issue #1744); lines whose box aspect is under 0.1 of the text's natural aspect are suppressed as misread rotations | | Default renderer since 17.0 | [M] | `fpdf_renderer/renderer.py` 536-630, 678-750, 751-840; `font/font_provider.py` 83-148 |
| OCRmyPDF docs | The sandwich renderer (Tesseract's text-only PDF): "some problematic PDF viewers like Mozilla PDF.js and macOS Preview have problems with segmenting its text output, and mightrunseveralwordstogether"; no RTL | | | [M] | advanced.html, "The sandwich renderer" |
| pdf.js `text_layer.js` | Each text item becomes a span scaled by `--scale-x = canvasWidth x measuredSize / (width x fontSize)`, so the selectable span is stretched to the item's drawn advance | | Word breaks are decided earlier, in the evaluator (RESEARCH §1) | [M] | lines 416-436 |
| veraPDF profile PDF/A-2b 6.2.11.4.1 | Font embedding test: `Subtype == Type3 || Subtype == Type0 || renderingMode == 3 || containsFontFile == true`; glyph-presence test likewise exempt in mode 3 | | So an invisible layer's font need not be embedded for 2b | [M] | `PDF_A/2b/.../6.2.11.4.1 General/*t01.xml`, `t02.xml` |
| veraPDF profile PDF/A-2u 6.2.11.7.2 | "The Font dictionary of all fonts shall define the map of all used character codes to Unicode values"; test `toUnicode != null`, no rendering-mode exemption | | Level U and A only | [M] | `PDF_A/2u/.../6.2.11.7.2/*t01.xml` |
| veraPDF profile PDF/UA-1 | 7.21.4.1 embedding test identical to PDF/A-2b's (mode-3 exempt); 7.1: "Content shall be marked as Artifact or tagged as real content" | | | [M] | `PDF_UA/1/7.21.../t01.xml`, `7.1 General/t03.xml` |
| Matterhorn Protocol 1.1 | Checkpoint 08: 08-001 "OCR-generated text contains significant errors", 08-002 "OCR-generated text is not tagged", both human-judged | | From search summaries citing the protocol; the PDF itself did not download | [?] | pdfa.org Matterhorn 1.1 (not read) |
| Amazon Textract docs | LINE and WORD blocks carry `BoundingBox` (Left, Top, Width, Height as 0-1 ratios) and a `Polygon` of points; a rotation angle; `TextType` PRINTED (or handwriting) per block | | | [M] | text-location.html |
| Azure Document Intelligence Read (v4.0) | Words carry `polygon` and `confidence`, lines `polygon`, paragraphs `boundingRegions`; `styles.isHandwritten` with confidence per span; searchable-PDF output for `prebuilt-read` at no added cost; limits 10,000 px, 500 MB, text at least 12 px on a 1024x768 image | | | [M] | prebuilt/read page |
| Google Document AI Enterprise OCR | Detects "blocks, paragraphs, lines, words, and symbols"; `tokens[].styleInfo` includes handwriting detection when `computeStyleInfo` is on | | Per-element polygon fields not stated on the page; price not stated | [M] for the quoted parts; geometry detail [?] | enterprise-document-ocr page (summary) |
| Mistral OCR 4.1 | Paragraph-level block boxes only (screen); $4 per 1,000 pages, $2 in batch | | | boxes [?]; price [M] | `J-compute.md` 263 |
| Surya README | Text-line detection returns `bbox`, a 4-point `polygon` clockwise from top left, and `confidence` | | Weights modified OpenRAIL-M (US$5M threshold); code Apache-2.0 | [M] | README 214-217; licence `I-inventory.md` |
| PaddleOCR text detection doc | `dt_polys`: "each box contains four vertices (x, y coordinates)", with `dt_scores`; PP-OCRv6 tiny det 0.43M params | | Apache-2.0 | [M] | text_detection.en.md 234-235, 51 |
| Kiessling, PP-OCRv6 for historical text (arXiv 2609.20064) | Raising the recogniser's line height from 48 to 96 px "accounts for almost all of the improvement", 8.3-11.5 macro CER points on CMMHWR task 1 | | Recognition only; placement unaffected | [M] | `pdf-kiessling/kiessling.txt` 169-179, 304-305 |
| Qwen3-VL issue 1231 | Qwen2.5-VL-72B word-level boxes "tend to align each line starting from the same x position" despite a prompt saying otherwise | | 2025-05-25, closed | [M] | GitHub issues API |
| D-enhancement.md (strand D) | Dewarpers predict a backward grid that is one line from being saved (UVDoc `point_positions2D`, DocRes `pred`); boxes found on the dewarped image are carried back to the original by reading the grid at their corners; PAGE-XML has no field for the transform | | | [M D note] | §5, §6.2 |

## 4. Code, weights, data and licences

| Item | What it gives placement | Licence | Mac | Cluster | Verdict |
|---|---|---|---|---|---|
| Apple Vision `VNRecognizeTextRequest` + `boundingBox(for:)` | Line polygons and word boxes (accurate level), free, already used for the truth pages | system | yes (macOS 10.15+) | no | R1 geometry source; word-box accuracy to be measured (test 2) |
| Apple `RecognizeDocumentsRequest` | Words, lines, paragraphs with polygons; no CJK/Thai words | system | macOS 26 only | no | Test beside the above on macOS 26 Macs |
| Vision OCR `SearchableWriter` + `alignedReading` (ours) | The writer and the aligner that exist and are measured on PDFKit | ours | yes | n/a | Build on; the integration plan's Stage 5 |
| local-llm-pdf-ocr | Reference design, not code to ship (Python, Surya, JPEG re-render) | MIT | yes | yes | Mined already; nothing new since |
| kraken (segmenter `blla`, `ForcedAlignmentTaskModel`) | Baselines with polygons; character cuts for a known transcript given a CTC model | Apache-2.0 | CPU (about 30 s a page to segment, one core, measured in `specialists.md`) | yes | Handwriting placement route (test 4); needs a kraken model per script (English hands: none in our lane yet) |
| Bullinger `nntp` | CTC transcript-to-lines alignment with confidence; a PyLaia path | paper CC BY 4.0; code licence not read [?] | PyTorch, CPU plausible [I] | yes | Alternative aligner for test 4; its models are 16th-century |
| Orli | Baselines in reading order, one model, zero-shot F1 0.934 on cBAD | Apache-2.0 | PyTorch; 1920x1440 input; speed unmeasured [?] | yes | Line detector candidate for handwriting and skewed photos (test 4) |
| PP-OCRv6 det (tiny/small/medium) | Quads per text line; ONNX variants | Apache-2.0 | ONNX Runtime / Core ML conversion [I] | yes | Cheapest shippable detector beside Vision; already in our FarmShare sweep as a reader |
| Surya detector | Line bbox + polygon + confidence | weights modified OpenRAIL-M (US$5M) | yes | yes | Test only; licence limits a distributed app |
| GutenOCR-3B / 7B | Line and word boxes by prompt; detection F1 0.80 in domain; 0.000 on handwritten notes | cc-by-nc-4.0 | GGUF ports; Qwen2.5-VL class, MLX plausible [I] | yes | Research comparison only (licence); tells us what a box-emitting VLM can do on typed pages |
| Unlimited-OCR (MIT), Nemotron-Parse 2.0 (OpenMDW), Surya-2, dots.ocr (MIT), LightOnOCR-3 `grounding` (Apache-2.0) | Block or line boxes with text, in one pass | as listed in `I-inventory.md` | MLX builds exist for Unlimited-OCR, Nemotron-Parse 2.0, dots.ocr, LightOnOCR-3 | yes | Candidates for the `replace` arrangement (block-level placement); box accuracy unmeasured |
| OCRmyPDF (fpdf2 renderer, `Occulta.ttf`, PDF/A path) | Reference writer for per-word `Tz` with a glyphless font, RTL, PDF/A-2b through Ghostscript or pikepdf validation | MPL-2.0 | yes | n/a | Read for design; not a dependency (Python, Ghostscript) |
| veraPDF | PDF/A and PDF/UA validation with the rule texts above | GPLv3 / MPL (CLI) | yes (Java) | n/a | Test 6 |
| READ-BAD / cBAD evaluation tool | The baseline coverage metric, Java | LGPLv3 | yes (Java) | n/a | Test 1; or reimplement Alg. 1-2 (about 100 lines) |
| Our truth set's `vision-words.json` | 100 pages of Vision word boxes in reading order | ours | n/a | n/a | The seed of a placement truth set: correct these boxes rather than draw from nothing |
| Public set N6 (heiDATA ALTO/PAGE) | 40 Devanagari pages with word or line geometry already | heiDATA terms [?] | n/a | n/a | Free line-geometry truth for one stratum; Vision gives no words for some scripts, so its value is as a detector test |
| Commercial: Azure DI Read, Textract, Document AI | Word polygons, handwriting flags; Azure writes the layer itself | paid | n/a | n/a | R6 reference points; prices in `J-compute.md` only for Mistral |

## 5. Comparison with what we measured

We have measured more of this than the field has published, on the only material that matters to us:

- **Print, position-free model onto Vision lines.** `OCR-COMPARE-2026-10-13`: Falcon-OCR through align halves the
  words wrong or missing (1.20% to 0.63%) on 56 print pages and lifts Find to 0.993, with Vision's placement kept.
  Nothing in the literature scores an aligned layer this way; local-llm-pdf-ocr's evaluation is two fixtures.
- **Handwriting, same route.** `HW-PLACE`: align places 65% of a strong reader's words and loses two thirds of its
  gain (96 missed per 1,000 as read becomes 367 in the PDF); the lab's decision was a text page for handwritten
  pages, and `HW-BUILD` shows the text page recovers Find (1,238 of 1,405 against 922). The cause is in
  `HW-COVERAGE`: Vision finds about 78% of handwritten lines and 82% of words, and misreads enough of what it finds
  (561 missed per 1,000) that the aligner's anchors fall under half on many lines. The literature's handwriting
  aligners (Bullinger, kraken) assume lines from a baseline segmenter, not from Vision, and the one line detector
  with published archival figures (Orli, cBAD F1 0.934) has never been run on our pages.
- **Viewer behaviour.** The lab's `score-corpus`, `score-line-separation` and `score-run-width` are the only
  controlled PDFKit measurements I can find anywhere; upstream's claims about Preview are screenshots. What
  transfers from upstream is the extractor threshold table (poppler 0.1 em, pdf.js 0.102 em, mupdf 0.15 em) and the
  warning that Tesseract's per-word runs with real spaces still weld in Preview.
- **Word-box accuracy.** We have 100 pages of Vision word boxes (`vision-words.json`) but no truth boxes, so the
  accuracy of the one geometry source every profile relies on is unmeasured, by us and by Apple ("not always an
  exact fit"). GutenOCR's F1@0.5 of 0.80 is on business and scientific scans and is the only published word-box
  figure for any VLM; its recall on handwritten notes is zero.

Where a public benchmark makes our own less necessary: for ranking line detectors against each other on European
archival handwriting, cBAD 2019 with the READ-BAD metric does the job, and Orli's paper already places Orli, Planet,
DocExtractor and ParseNet on it; we should not rebuild that comparison. For everything about our own material
(phone photographs, typed 20th-century pages, Vision as the detector, PDFKit as the viewer), the public sets are
scans and the metric was never applied to a text layer, so our tests stand.

What to borrow and run ourselves: the READ-BAD coverage metric as the line-level placement score (it is skew-tolerant,
needs no binarisation, and our hypothesis baselines fall out of the writer's line boxes at `baselineFraction`);
GutenOCR's F1@0.5 and mCER@0.5 protocol for word boxes (match at IoU 0.5, then score text on the matched set, so
"found the right place" and "read it right" separate); Bullinger's line-level alignment accuracy and its γ6
confidence as the gate for a forced-alignment route; Orli's zero-shot cBAD and reading-order protocol as the way to
check any line detector we adopt before it touches our pages.

## 6. Strand-specific questions

### 6.1 Where word positions come from, by profile, and how accurate each is

Three sources, and a profile picks by what its reader returns.

1. **The reader's own positions** (R1 Vision; R2 position-emitting open models; R6 cloud OCR). Vision gives a line
   polygon and, at `.accurate`, a word box per word [M Apple]; on macOS 26 `RecognizeDocumentsRequest` gives words
   directly but none for CJK or Thai [M]. Cloud OCR gives word polygons and handwriting flags (Azure, Textract,
   Document AI) [M docs]. Among open VLMs, GutenOCR is the only one with a measured word-box F1 (0.80 in domain,
   axis-aligned boxes only, zero on handwritten notes, cc-by-nc) [M]; the others emit block or line boxes whose
   accuracy nobody has measured, and generative boxes have a known failure of snapping line starts to one x [M
   issue 1231]. Accuracy on our pages: unmeasured for all of them. Vision's is the one to measure first (test 2),
   because every other route in the app inherits it.
2. **A position-free reader aligned onto detector lines** (R2 chat models, R3, R4, R5, and R6 services that return
   text only). Our `alignedReading` does this on Vision's words and is measured: a real gain on print, a failure on
   handwriting (section 5). The detector could instead be PP-OCRv6's `dt_polys`, Surya's polygons, kraken's
   baselines or Orli's ordered baselines; none has been tried as the geometry under our aligner, and the handwriting
   result says the detector, not the aligner, is the limit there. Accuracy for this route is a function of three
   things we can measure separately: detector coverage of the ink (baseline coverage R), anchor share (how often the
   reader's words and the detector's reading agree), and the within-line placement of words (proportional by
   character count in our writer and in local-llm-pdf-ocr; by recogniser cuts in kraken).
3. **Forced alignment through a CTC recogniser** (R2 and R7, handwriting). Given lines and a transcript, the
   Bullinger method or kraken's `ForcedAlignmentTaskModel` places the transcript line by line using the recogniser's
   posteriors rather than its text, so a weak recogniser suffices (weaker models aligned better: 88.5-89.1% line
   accuracy at 15 epochs) [M]. It gives character cuts inside the line as a by-product [M kraken]. It needs a CTC
   model whose alphabet covers the text, per script; for 20th-century English hands the kraken lane has none yet.

For the profiles: R1 uses Vision's own words and the layer already exists; R2 with a small open reader (PP-OCRv6 or
a line-box VLM) can use the reader's lines, R2 with a chat model aligns onto Vision or a detector; R3, R4 and R5
return text only and align; R6 services return word polygons and can write the layer from them directly (Azure
writes it itself); R7 can afford a detector plus forced alignment per page; R8 is the cascade the integration plan
already names, Vision first for geometry, then a reader per kind.

### 6.2 A placement metric we can compute on our pages, and the truth it needs

Three levels, from cheapest truth to most, all computable on the 96 truth pages and the public strata.

- **Functional, on the rendered PDF (what the user feels).** For every truth word of four or more letters: does
  PDFKit `findString` return a hit, and does the hit's selection bounds intersect the word's ink box? Report Find
  rate, placed-hit rate, and the lab's three instruments (`words=`, `merged=`/`welded=`, run width). Truth needed:
  a word box per truth word for a subset of pages. `HW-PLACE` already computes Find without boxes; the box adds
  "in the right place".
- **Selection is a line, not a word (owner, 2026-10-29).** What matters for selection is that the user can select
  every word of a line of text, in order, as one line. On skewed or warped pages each word is often selectable on its
  own while a drag along the line returns the words out of order, mixed with a neighbouring line, or broken across
  lines, so a per-word score (Find, placed-hit, word F1) is no evidence of selection. The selection score is per truth
  line: a PDFKit drag (`selection(from:to:)`) from the start of the line's first truth word to the end of its last, and
  the line passes when the selected string, whitespace collapsed, is the truth line's words in their order, with no
  line break inside, no word from another line and none missing. Report the share of truth lines that pass, by tag
  (skew, perspective, curl, hand). Find and highlight stay as scores of their own and are never reported as
  selection. Prior instrument: vision-ocr `Tools/pdfkit-drag.swift` (column drags; its note on `characterBounds`
  falling out of step with `page.string` applies here).
- **Word level, F1@IoU 0.5 and 0.7** as in GutenOCR, over the layer's word rectangles (our writer draws a line run;
  its word rectangles come from the run's glyph advances, which `score-run-width` already reads back) against truth
  word boxes; and mCER@0.5 over matched pairs. Truth needed: word boxes.
- **Line level, READ-BAD coverage R, P, F** over baselines: hypothesis baselines from the layer's line boxes at
  `baselineFraction`, truth baselines drawn by hand. It is tolerant to skew and to small vertical offsets, which is
  right for photographs, and the Java tool exists (LGPLv3) or Alg. 1-2 reimplements in about 100 lines. Truth
  needed: a polyline per text line, the cheapest geometry to draw (one stroke per line).

The truth set to build: 40 typed or printed and 20 handwritten owner truth pages, plus 20 public pages from L1/L2
(English hands) and the 40 N6 pages whose ALTO/PAGE geometry comes free. For typed pages, start from
`vision-words.json` and correct boxes in a small tool rather than draw from nothing (the 2.7 MB file covers all 100
pages, and `locate.py` already ties truth spans to those words); for handwriting, Vision misses 18-22% of words, so
the missing ones are drawn. Store PAGE-XML (Aletheia reads it; the READ-BAD tool reads it). One more cheap addition:
line-broken truth for the same pages (the current transcripts are one line per page), which turns the Bullinger
line-level alignment accuracy into a metric we can compute for any aligner. About 8 minutes a typed page and 15 a
handwritten page for the owner or a reviewer, roughly two sessions.

### 6.3 Handwriting placement

The measured position: align through Vision places 65% and the text page wins today [M HW-PLACE]. The two levers,
in the order to pull them:

1. **Lines from a baseline segmenter instead of Vision.** `HW-COVERAGE` puts Vision's handwriting line coverage near
   78% of lines; `hw-qwen.md` notes kraken's own `blla` segmenter "would lift the cap, not the reading", and was not
   run. Orli (zero-shot cBAD F1 0.934, reading order built in, Apache-2.0) and `blla` are the candidates; PP-OCRv6's
   detector and Surya's are print-trained and the third choice. The settling measure is baseline coverage on
   hand-drawn baselines for the 21 handwriting truth pages and 40 L1/L2 public pages.
2. **Forced alignment of the chosen reader's transcript onto those lines.** The Bullinger method or kraken's
   `ForcedAlignmentTaskModel` places the VLM's text (the reading we trust, 91-96 missed per 1,000) by a CTC model's
   posteriors (a reading we do not trust) and never drops transcript words [M]. Expected line-level accuracy on
   16th-century letters was 86-89% with models of 0.8-7.4M parameters [M]; on 20th-century English cursive with a
   kraken English model it is unmeasured. Within the line, kraken's cuts give character positions for word
   rectangles; proportional character count is the fallback and is what every production writer uses anyway.
3. **Block-level placement from a box-emitting reader** (`replace` arrangement), named in `hw-qwen.md` as untried:
   LightOnOCR-3's `grounding` boxes or Nemotron-Parse's. It places a paragraph's text in its block with lines
   proportioned by character count; selection by line would be approximate, Find would land in the right block.
   GutenOCR's zero recall on OmniDocBench's handwritten notes [M] says do not expect line boxes from print-trained
   VLMs on handwriting.

The fallback stays: a page whose anchor share or baseline coverage is under threshold gets the text page, and the
run report names it (the lab's `Unplaced` reporting and the Processor's page-2 format both exist).

### 6.4 When the VLM's text and the detector's lines disagree

Four cases, what each tool does, and the rule I would adopt:

- **Lines the detector missed.** Text with no home. Our aligner leaves model words out unless they fall between two
  anchors on one line (at most three) [M]; local-llm-pdf-ocr attaches a skipped line to the last matched box [M
  PRIOR-ART]; Bullinger never drops text and opens a gap with extra newlines [M]. Rule: no text is lost; words the
  layer cannot place go to an unplaced run or the text page, and the count is reported per page (invariant 1 of
  the lab).
- **Extra text from the model.** Model notes ("Note: The handwritten text contains some unclear...", published on
  p049 [M hw-qwen]), Markdown and tags (stripped by `modelText` [M]), repeats and loops (Churro's 12,000-token p096
  [M HW-PANEL]). Rule: strip markup, cap insertions (our 3-per-gap rule), and treat a reading whose word count
  exceeds the detector's by a large factor as a failed page.
- **Reading-order differences.** Columns, marginalia, tables. local-llm-pdf-ocr aligns under two orders and keeps the
  cheaper [M]; ours orders by `columnOrdered` and, when under half the words anchor, keeps Vision's reading [M].
  Orli's ordered baselines would give a third order to test against [M]. Rule: a low anchor share is a signal to
  fall back, not to reorder the layer.
- **Hyphenation.** The single largest error class in Transkribus-aligned data [M Bullinger]. Ours joins a hyphenated
  line-end word with the next line's first word for alignment and splits it where Vision split it, refusing when
  the lengths differ by more than one [M]. Keep.

### 6.5 Dewarped against original, and which image carries the layer

Strand D settled the geometry: OCR the dewarped image, keep the backward grid, and carry each box back to the
original by reading the grid at its corners [M D note §5]. What this strand adds is which image the layer should
sit on. A PDF text run is straight; a line carried back to a curled photograph is not. Our writer handles whole
regions turned by quarter turns (`layer.transform`) and OCRmyPDF handles a sloped straight baseline per line, but
neither places a run along a curve, and doing it would mean per-word runs each with its own text matrix, which is
where the word-spacing failures of section 6.6 come from. So: when the user turns dewarping on, the reading copy is
the dewarped image and the layer is placed on it directly, no mapping needed; when dewarping is off, the reading
copy is the original and the layer must be mapped back, which is exact for a perspective-only correction (a
homography keeps lines straight, so a sloped straight run per line suffices) and approximate for a curl (a straight
run across a curved line, the error being the sagitta of the curve in pixels; test 8 measures it). PAGE-XML cannot
record the transform, so the grid is stored beside the page [M OCR-D via D note].

### 6.6 Viewer behaviour, PDF/A and PDF/UA

What is established:

- **Word spacing is re-derived from geometry by every viewer but mupdf.** Thresholds: poppler 0.1 em, pdf.js 0.102 em,
  mupdf 0.15 em, PDFKit about 0.15 em (ours, measured) [M RESEARCH §1]. A real space character does not remove the
  need for a drawn gap. Tesseract's per-word design with real spaces still welds words in Preview and PDF.js
  per OCRmyPDF's own docs [M]. Our 0.25 em reserve sits inside the window where all three readable extractors see
  a break and none doubles it [M].
- **pdf.js stretches each span to its drawn advance** (`--scale-x`) [M], so selection follows the drawn width of the
  run whatever the font; its word breaks come from the evaluator's 0.102 em rule.
- **Acrobat: no source.** Nothing authoritative was found on how Acrobat segments an invisible layer; it is the one
  viewer test 5 has to run by hand.
- **PDF/A-2b is reachable with an unembedded font.** veraPDF's embedding test exempts fonts used in rendering mode 3
  [M], which is why OCRmyPDF's PDF/A output passes with Tesseract's glyphless font and why our Helvetica layer need
  not embed either. **PDF/A-2u and 2a require a ToUnicode map for every font** with no mode-3 exemption [M]; a
  glyphless or custom font must carry one, and Ghostscript 10.05-10.06 drop multi-character ToUnicode entries, which
  is why OCRmyPDF turns ligature shaping off for invisible text [M]. Our current Helvetica WinAnsi run has an
  implicit Unicode mapping that veraPDF derives from the encoding, but that is my inference [I]; test 6 validates.
- **PDF/UA is not a realistic claim for OCR output.** PDF/UA-1 requires every content item to be tagged or marked
  Artifact [M 7.1-t03], and Matterhorn's OCR checkpoint fails a file for significant OCR errors or untagged OCR text,
  both judged by a human [?]. A tagged layer (one `P` per paragraph, `Lang`, reading order) is possible and would
  help screen readers, but the "no significant errors" condition cannot be met on a 30%-error newspaper page. Treat
  PDF/UA as out of scope and PDF/A-2b (or 2u with ToUnicode) as the archival target.
- **RTL and complex scripts.** OCRmyPDF encodes RTL words 1:1 in logical order with a mirrored text matrix [M]; our
  writer has no RTL path, and the public set has Hebrew and Arabic strata. Apple gives no word boxes for CJK or
  Thai [M]. Open question 3.

### 6.7 When a separate text page is still necessary

1. **Text the layer cannot locate.** Today: handwritten pages (65% placed) [M]; also any page whose detector
   coverage or anchor share is under threshold, and blurred photographs (p094: 25% of words in a box). The text
   page is the no-loss fallback and the run report names the pages.
2. **Model-normalised text.** olmOCR-2 modernises spelling [M PRIOR-ART §2]; historians' transcriptions expand
   abbreviations and add punctuation [M Bullinger §3.1]; a VLM asked for a diplomatic reading still regularises. Such
   text cannot be placed character-accurately and is a transcription, not a layer; it belongs on a text page or
   beside a layer of the detector's own reading.
3. **Marks transcribed separately** (strand D §6.5): a stamp's or annotation's transcript labelled as a mark. It can
   be placed as a run at the mark's box, but a label like "[stamp: ...]" breaks selection and Find semantics; a PDF
   annotation (FreeText with the transcript, or a Popup) or the text page is cleaner [I]. Decide in test 9.
4. **The Processor's metadata header.** Provider, model, OCR date, Classification, Document date and Sent with live
   on page 2 and are parsed by `PDFHeaderParser` in both apps [M SPEC]. A layer-only output needs another carrier
   (XMP or the Info dictionary) and a coordinated spec change, or the text page stays as the header's home. The
   owner's decision 2 already allows "text present twice" (image with layer, then text page) [M integration plan].
5. **Scripts without word boxes or without an RTL path** (CJK, Thai, Hebrew, Arabic) until 6.6's open question is
   settled.
6. **Tables and multi-column pages where the layer's reading order is poor**: the layer still finds words; the text
   page gives the order a copy needs.

## 7. Tests to run on our material, ranked

Costs use the truth draft's measured Gemini price, $0.369 for 111 calls, about $0.0033 a page. The both-sets rule of
2026-10-20 applies: any model run on the 895-page public set is run on the 96 truth pages with the same settings in
the same item, truth pages first. Readings already saved by the panels are reused where a test needs a reader's
text, so most of these cost nothing.

1. **The placement truth set and scorer.** Profiles: all (it is the Phase-2 "position accuracy score"). Build the
   truth of 6.2: corrected word boxes and hand baselines on 40 typed, 20 handwritten owner truth pages, 20 L1/L2
   public pages, plus N6's free ALTO/PAGE geometry; line-broken transcripts for the same pages. Implement the three
   scores (functional Find-in-place, F1@0.5/0.7 with mCER@0.5, READ-BAD coverage F) over any PDF the writer
   produces, reading word rectangles back through PDFKit as `score-run-width` does. Free; owner or reviewer time
   about two sessions.
2. **Vision's own geometry.** Profile: R1 and everyone downstream. Word boxes from `boundingBox(for:)` at `.accurate`
   (macOS 15 `RecognizeTextRequest`) and from `RecognizeDocumentsRequest.words` (macOS 26) against the truth boxes:
   F1@0.5 and 0.7 by kind, baseline coverage by kind, and the share of truth words with no Vision box (the
   handwriting cap). Free, Mac.
3. **The align arrangement scored properly.** Profiles: R2-R5. The saved readings of Gemini 3.8 Flash, Qwen3.6 27B,
   LightOnOCR-3-4B and Falcon-OCR for the 96 truth pages, placed through `alignedReading` on Vision's lines, scored
   with test 1's three scores plus `HW-PLACE`'s placed and kept. Output: per-kind placement figures for the router's
   table and the anchor-share threshold at which the text page wins. Free (readings exist).
4. **Handwriting: detector plus forced alignment.** Profiles: R2 (laptop, small models) and R7. Step one: kraken
   `blla`, Orli high-res, PP-OCRv6 det and Surya det on the 21 handwriting truth pages and 160 L1/L2 public pages,
   baseline coverage R/P/F against the hand baselines, and the share of truth words inside some line. Step two: on
   the best detector's lines, place LightOnOCR-3's and Gemini's readings by kraken's `ForcedAlignmentTaskModel` (an
   English-hand kraken model from the Zenodo catalogue, or the Bullinger `nntp` code with a PyLaia model) and by our
   proportional aligner; score line-level alignment accuracy against the line-broken truth and the functional score.
   Decision: whether handwritten pages can leave the text page. Free: detectors on the Mac, alignment on
   FarmShare or Sherlock (kraken runs on CPU; Orli on a GPU).
5. **Viewer test of three writer designs.** Profiles: all. Ten typed and five newspaper truth pages written three
   ways: ours (per-line run, font-size fit, 0.25 em reserve), OCRmyPDF's (per-word `Tz` in one BT block, glyphless
   font, trailing spaces), and per-word runs with real spaces and no reserve. Score with the lab's instruments on
   PDFKit, with `pdftotext` (poppler), `mutool` and pdf.js's text extraction in node; the owner opens the same 15 in
   Acrobat Reader and records selection and Find for ten words a page (about 20 minutes). Free.
6. **PDF/A validation.** Profiles: all. veraPDF over 20 of our PDFs for PDF/A-2b and 2u; if 2u fails on ToUnicode,
   add a ToUnicode CMap to the layer's font and re-validate. Free.
7. **Box-emitting readers on typed pages.** Profiles: R2, R7. GutenOCR-3B (research only), Unlimited-OCR,
   Nemotron-Parse 2.0, Surya-2 and PP-OCRv6 det on the 96 truth pages, their line or word boxes scored by F1@0.5
   and mCER@0.5 against test 1's truth, beside Vision's. If any is extended to the public set, the truth pages run
   in the same item. Free on FarmShare or Sherlock; the small ones on the Mac. Paid variant: Gemini 3.8 Flash asked
   for line boxes on the 96 pages, about $0.32, only if the open models fail, since generative boxes have a known
   indentation failure.
8. **Dewarp round trip for the layer.** Profiles: all (shared with strand D's test 1). Twenty line boxes per page on
   20 curved truth pages carried back through the saved UVDoc grid: corner error in pixels and the sagitta of each
   mapped baseline, which is the error of a straight run on the original. Decides 6.5's rule. Free.
9. **Marks in the layer.** Profile: all (evidence rule). On strand D's 150-page marks set once it exists: mark
   transcripts as labelled runs, as FreeText annotations, and on the text page; Reader's Find and selection
   behaviour for each, and whether Spotlight indexes the annotation text. Free.

## 8. Open questions

1. Acrobat's segmentation of an invisible layer has no written source; only test 5's manual pass answers it.
2. Whether a standard-14 Helvetica run without an explicit ToUnicode passes PDF/A-2u in veraPDF, or whether we need a
   CMap; test 6.
3. RTL and complex scripts in our writer (none today) and word boxes for CJK and Thai (Apple gives none); the public
   set's N1 and N4 strata need a decision before any layer is written for them.
4. Which kraken or PyLaia model covers 20th-century English cursive well enough for forced alignment; the kraken lane
   in `specialists.md` ran only L5-L7, N3 and N4 models. Bullinger's finding that a weak model aligns well lowers
   the bar.
5. Orli's parameter count and speed per page are not in the paper; both decide whether it is an R2 or an R7 tool.
6. Whether the public strata beyond N6 carry line geometry in their sources (By the People is text only; Bentham,
   READ 2017, Königsfelden and HTR-United usually ship PAGE-XML with baselines, which is an inference); worth one
   look before drawing baselines by hand for L1/L2.
7. The metadata header's carrier if a layer-only output is ever offered (section 6.7, item 4): a SPEC change for
   both apps.
8. Matterhorn 08's exact wording was not read (the PDF did not download); the conclusion that PDF/UA is out of
   scope does not depend on it.

## 9. Routes

Mac-runnable is an attribute, not a filter. "Settling test" numbers refer to section 7.

| Route | Best candidates for placement | Evidence | Licence by route | Settling test |
|---|---|---|---|---|
| R1 Mac built-in (Vision, Core ML, Foundation Models) | Vision `RecognizeTextRequest` lines and `boundingBox(for:)` word boxes; `RecognizeDocumentsRequest` words on macOS 26; our `SearchableWriter`. Foundation Models give text only (align onto Vision) | Word precision at `.accurate` [M Apple]; print Find 0.989, selection figures [M lab]; handwriting coverage about 78% of lines [M, by eye] | system; our code | 2, 5, 6 |
| R2 Mac open weights (16 / 32 / 64 GB+) | 16 GB: PP-OCRv6 det quads (Apache-2.0, 0.43M-tiny) under a small reader, or Vision lines plus Falcon-OCR align; 32 GB: LightOnOCR-3-4B text aligned onto Vision (print) with the text page for handwriting as shipped; `replace` from Unlimited-OCR / Nemotron-Parse 2.0 / LightOnOCR `grounding` block boxes; 64 GB+: kraken `blla` or Orli lines plus `ForcedAlignmentTaskModel` for handwriting; GutenOCR research-only | Falcon align 0.63% [M]; HW-PLACE 65% placed [M]; detector and forced-alignment accuracy on our pages: none yet | Apache-2.0 (PP-OCRv6, Orli, kraken, LightOnOCR-3), MIT (Unlimited-OCR, dots.ocr), OpenMDW (Nemotron-Parse), OpenRAIL-M US$5M (Surya), cc-by-nc (GutenOCR: test only) | 3, 4, 7 |
| R3 cheap API (OpenRouter) | Text only from every model there; align onto Vision lines (print) or a Mac detector; text page fallback | Same aligner evidence as R2; Qwen3-VL grounding boxes exist but snap line starts [M issue 1231] | the model's; placement code ours | 3 |
| R4 premium API (Gemini, Claude, OpenAI, Mistral; batch) | Text only (Gemini, Claude, OpenAI) aligned onto Vision or a detector; Mistral OCR 4.1 paragraph boxes feed `replace` at block level ($4 / 1,000 pages, $2 batch) | Gemini readings exist for the 96 pages; placement unmeasured beyond align on print | provider terms | 3, 7 (paid variant about $0.32) |
| R5 subscriptions via a local agent CLI (Claude, ChatGPT plans) | Text only, through the Processor's `LocalAgentClient`; align onto Vision; text page fallback | No positions possible; the aligner carries everything | plan terms; no API cost | 3 |
| R6 commercial document services | Azure DI Read: word polygons, `isHandwritten`, and it writes the searchable PDF itself at no added cost; Textract: WORD/LINE boxes and polygons, `TextType`; Document AI: words and symbols, `styleInfo` handwriting; Transkribus: baselines and Text2Image alignment (hyphenation errors documented); Extend: not surveyed | Geometry [M docs]; accuracy on our pages: none; prices not in `J-compute.md` except Mistral | paid, closed | None planned under the paid-run hold; one 20-page Azure trial (free tier handles 2 pages a file) would give a word-polygon reference at $0 if ever needed |
| R7 cluster (Sherlock design target; FarmShare) | Orli and kraken `blla` for lines, kraken / `nntp` forced alignment of any reader's transcript onto them, GutenOCR-7B and Surya-2 for box-emitting comparison; the UVDoc grid round trip for dewarped pages | cBAD F1 0.934 zero-shot [M Orli]; line alignment 86-89% on 16th-c. letters [M Bullinger]; nothing yet on ours | Apache-2.0, CC BY, cc-by-nc acceptable in a user's own kit; weights stay off the app | 4, 7, 8 |
| R8 hybrids | The integration plan's cascade: Vision first for geometry and the print layer; a reader per kind aligned onto those lines; a detector-plus-forced-alignment stage for handwriting on the cluster or a 64 GB Mac; the text page whenever placement falls under threshold, reported per page; dewarp on means the layer sits on the dewarped reading copy | HW-BUILD: text page lifts Find 922 to 1,238 of 1,405 [M] | as above by stage | 3, 4, 8, 9 |
