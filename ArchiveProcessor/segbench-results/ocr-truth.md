# W41.ocr-truth — the transcription truth set

Drawn 2026-10-14 by `ArchiveProcessor/scripts/segbench/ocr_truth.py` (seed 41), read only on `Archival Photos` and `Archival Photos JPEGS`. The pages, their table, both drafts and the review sheet are outside git, under `~/Library/Caches/ArchiveSuiteRehearsal/ocr-truth/`; this file holds numbers only. The draw's rule is in the script's header, fixed before the draw ran.

**Drafted by two models, so the truth leans toward them:** Claude Opus 5.5 (claude -p, subscription) and Gemini 3.8 Flash (OpenRouter, Google AI Studio). Where their readings agree word for word (after straightening quotes and dashes and ignoring line breaks and table bars) the agreed text stands; every other span goes to the owner.

## The draw

100 pages, one per document, from 33 collections and 58 folders. The pool: 21,105 implied documents. 19 drawn pages were replaced for having under 20 words in Apple Vision's reading; 0 could not be read from disk.

The filter read every candidate with Apple Vision (macOS 26.6), so no page where Vision read fewer than 20 words is in the set: every comparison with Vision on these pages, and every suspect rate or cascade figure that uses Vision as the second reader, is on pages Vision could read. The 19 replaced pages, by their folder tags (no page was read for this): 4 tagged Handwritten, written pages Vision could not read rather than covers or blanks, so the handwritten pages kept are all hands Vision read at least 20 words of; 2 tagged Images worth reproducing, 2 a tree diagram, 1 a clipping; 10 carry no kind tag, so what they hold is not known without reading them. Vision's word counts: 0, 0, 4, 5, 6, 8, 10, 10, 10, 11, 12, 14, 15, 15, 17, 17, 18, 18, 19.

| Vision words | drawn for | kind tag |
|---:|---|---|
| 0 | cover Harvard University Archives | no kind tag |
| 0 | stratum 1900-1949 | no kind tag |
| 4 | stratum undated | Images worth reproducing |
| 5 | stratum undated | no kind tag |
| 6 | stratum handwritten | Handwritten |
| 8 | stratum handwritten | Handwritten |
| 10 | fill | Images worth reproducing |
| 10 | fill | a tree diagram |
| 10 | stratum 1985 on | no kind tag |
| 11 | stratum undated | no kind tag |
| 12 | stratum before 1900 | no kind tag |
| 14 | stratum undated | no kind tag |
| 15 | stratum 1900-1949 | no kind tag |
| 15 | stratum handwritten | Handwritten |
| 17 | cover Huntington Library | a tree diagram |
| 17 | fill | no kind tag |
| 18 | stratum handwritten | Handwritten |
| 18 | stratum undated | no kind tag |
| 19 | cover Stanford University Archives | Clippings |

| stratum | pool (documents) | pages | from the original photo |
|---|---:|---:|---:|
| before 1900 | 63 | 12 | 9 (75%) |
| 1900-1949 | 1,920 | 14 | 5 (36%) |
| 1950-1984 | 14,877 | 49 | 40 (82%) |
| 1985 on | 1,913 | 12 | 7 (58%) |
| undated | 2,332 | 13 | 6 (46%) |
| handwritten | 139 | 12 | 12 (100%) |
| clippings | 2,187 | 13 | 6 (46%) |
| tables | 456 | 12 | 7 (58%) |
| **all** | 21,105 | 100 | 67 (67%) |

Where there was no single original, the image inside the PDF was used: original 67, pdf image (no original) 32, pdf image (2 originals) 1.

Photo attributes, tertiles cut on a random sample of originals (long side 2592/2592 px, sharpness 699/1407, year taken 2016/2018):

| attribute | low | middle | high |
|---|---:|---:|---:|
| long side | 21 | 43 | 36 |
| sharpness | 34 | 33 | 33 |
| year taken | 9 | 35 | 56 |

Cameras: Apple iPad 38, (no EXIF camera) 33, Google Pixel 9 8, Apple iPhone 6 6, Apple iPad mini 6, Apple iPad mini 2 5, Google Pixel 6 3, Google Pixel 4a 1.

Per collection: American Jewish Committee Archives 1, Babbage 2, Bancroft Library 1, Cambridge 8, Center for Jewish History 1, Chicago, University of, Archives 6, Columbia University 1, Complete Journals 6, Computer History Museum 5, General Clippings 4, HBS 2, Harvard Law School 1, Harvard University Archives 8, Hoover Institute 8, Huntington Library 3, Library of Congress 1, London School of Economics 1, NARA 1, NYPL 3, Northwestern 2, Northwestern University 3, Othmer 1, Personal collections 1, San Jose State 1, Stanford University Archives 8, Stanford University Archives — Tech 8, Swarthmore Archives 1, UC Santa Cruz 1, UIUC 1, UNLV 1, USC 4, University of Rhode Island 1, Wisconsin Historical Society 4.

Resolution ladder: 20 pages also at half and a quarter of their pixel size (chosen across the pixel tertiles, the largest first).

## The drafts

Both drafts for 100 of 100 pages. 33 pages agree word for word. 416 disputed spans covering 1,000 of 31,184 words (3%). The two models give the same kind of writing on 87 pages.

| kind (Claude's label) | pages | words | disputed words | pages agreed |
|---|---:|---:|---:|---:|
| printed | 29 | 12,868 | 414 (3%) | 10 |
| typewritten | 50 | 15,140 | 279 (2%) | 23 |
| handwritten | 19 | 2,950 | 265 (9%) | 0 |
| mixed | 2 | 226 | 42 (19%) | 0 |

Gemini 3.8 Flash cost $0.369 over 111 calls, retries and probes included. Its drafts by provider: Google AI Studio 98, Google 2 (AI Studio ended two pages of reprinted published text with an error and no tokens on every try; Google's Vertex endpoint, the same model, answered them). Claude: $0 (subscription).

## The review

The review sheet holds 416 spans on 100 pages, about **89 minutes** at 10 s a page (the kind of writing), 6 s a span and 30 s for the 15% assumed to need a typed correction (an estimate, not measured). One keystroke per choice; the answers are exported as JSON and applied with `ocr_truth.py apply`, which writes `truth/<page>.txt` and the page table `pages.tsv` the panels group by (a kind of writing the two models agree on and the owner leaves alone counts as confirmed). The truth is a word sequence: line breaks and table bars are not kept, so a panel is scored on the words in order, with whitespace normalised (as socOCRbench's NES and chrF do).

## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. This report is that truth's construction; the 100 drawn pages hold the three agreement-only letters the 96 leave out.
- **Selection.** The draw rule in the script's header, fixed before it ran (seed 41, one page per document, stratified by date and kind); no route's accuracy or ABBYY text chose a page, but Vision's word count did. Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read. The 15 PDF images with a confirmed original were later replaced by their camera JPEGs (W46.truth-jpeg-upgrade, 2026-10-29); their truth was drafted from the PDF images, which favours a reading of those.
- **Comparison.** No route is scored here. The two drafters are the only readings: a span they wrote alike stands unchecked unless a later blind sample reached it, so a route of either drafter's family can gain where the truth shares its mistake.
- **Noise.** The counts are of this one draft pair; the review time is an estimate. The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie.
- **Scope.** A word sequence only, with no line breaks, layout or reading-order truth; 100 pages over 33 collections, so no per-collection figure; only pages Vision could read.

