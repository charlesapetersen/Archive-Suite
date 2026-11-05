# W46.r6-spot — Azure Document Intelligence, AWS Textract and Transkribus on 25 of the 96

Script: `ArchiveProcessor/scripts/segbench/r6_spot.py` (`select`, `run azure|textract`, `report`). Raw replies,
selection and ledger in `~/Library/Caches/ArchiveSuiteRehearsal/r6-spot/` (outside git). Run 2026-11-04.

Routes: Azure DI `prebuilt-layout` (API 2024-11-30, F0 free tier, $0); Textract `AnalyzeDocument` with LAYOUT and
one QUERY ("What is the date of this document?"), us-east-2, $0.475 accounted at list ($0.019 a page).

## OCR (mean NES on the same 25 pages, panel scorer `ocr_panel_score.score`)

| route | mean NES |
|---|---|
| gpt5.4-mini | 96.4 |
| claude-sonnet5.5 | 95.9 |
| qwen3.5-397b | 95.4 |
| qwen3-vl-235b | 93.8 |
| gpt5.6-luna | 92.8 |
| mistral-ocr-4-1 | 92.5 |
| mistral-large4 | 91.8 |
| mistral-medium3.5 | 91.5 |
| **azure-di-layout** | **89.6** |
| **textract-layout** (lines in LAYOUT block order) | **86.6** |
| textract-lines (raw LINE order) | 83.4 |
| **transkribus-text-titan** (PAGE XML, the export's reading order) | **82.5** |

Paired against Mistral OCR 4.1 (10,000 bootstrap rounds): Azure −2.9 NES points (interval −6.3 to −0.2);
Textract layout −5.8 (−13.4 to +1.5, a tie at n = 25). Textract's LAYOUT ordering adds 3.2 points over its raw
line order, so its reading order is part of the gap.

## Transkribus (owner's hand upload, scored 2026-11-05)

**Model:** "Text Titan I" as the owner read it in Transkribus (PAGE XML Creator: TrHtr 2.52.0, model_id 356425),
with layout analysis on. This **substitutes for Text Titan II**, which the item asked for and which was not
offered on the owner's Stanford account. Uploaded and exported by the owner at app.transkribus.org on free
credits (about 25 of the monthly 50), $0. Export: `r6-spot/transkribus-pack/export/` (25 PAGE XML files, 17 to
111 lines each, every page with text). `r6_spot.py report` reads the lines in the export's own order (regions by
`ReadingOrder`, lines by their `readingOrder` index) and maps Transkribus's line-end hyphen `¬` back to `-`, as
the truth keeps the printed hyphen (82.4 without the mapping).

- **82.5 mean NES**, the lowest vendor here. Paired: −10.0 against Mistral OCR 4.1 (−16.9 to −4.5), −7.1 against
  Azure (−13.6 to −2.1), −4.1 against Textract layout (−11.5 to +3.0, a tie).
- By kind: typewritten 92.2 (14 pages), printed 71.0 (7), handwritten 76.2 (2), mixed 60.6 (2). On the two
  handwritten pages it is level with Azure (p007 64.6 against 56.1, p051 87.7 against 91.6); n = 2 settles nothing.
- **Reading and order both cost it.** Order-free, it misses 11.6% of the 8,276 truth words, against 2.9% for Azure
  and 3.0% for Textract. Its layout analysis also reads multi-column pages across the columns: p064, a two-column
  code list, is one region whose lines alternate between columns (50.0 NES with 13 of 129 words missed), and
  p065, p062 and p018 lose most of their score the same way.

## Date entity (Textract QUERIES), a weak check

Answered 22 of 25; a four-digit year in 13. The year matches one of the folder's year or decade tags on 7 of 12
pages that have both, and lies in the page's date bin on the same 7 of 12. Tags are the folder's, not
per-page date truth, so this says only that the vendor's date answer is not a usable year source as it stands.

## Handwriting flag (Azure `isHandwritten`)

The handwritten share of the text is 0.85 and 0.86 on the two pages tagged handwritten, 0.38 and 0.93 on the two
mixed pages, and 0.00 to 0.05 on all 21 printed or typewritten pages: on this sample the flag separates the kinds.

## Custom splitters, a price read (no run)

List prices read 2026-11-04 from the vendors' pricing pages as quoted by search results, not checked against a
bill: Google Document AI Custom Splitter (and custom classifier) $5 per 1,000 pages up to 1 million a month;
Azure Document Intelligence custom classification $3 per 1,000 pages. Both need labelled training documents
and a cloud project; Document AI has no account here. At these prices 100,000 pages cost $500 (Document AI) or
$300 (Azure). The corpus is ~102k PDFs, so a full pass is $510 or $306 at one page a PDF and $1,020-1,530 or
$612-918 at 2 to 3 pages a PDF: hundreds of dollars, so price is a real constraint on a custom splitter, and a
corpus pass would need the owner's word under the $7 rule. (An earlier version of this paragraph said "under
$1.50 for a full pass"; $1.50 at $5 per 1,000 is 300 pages. Corrected by W46.r6-spot-price, measurement review
2026-11-05 P9-4.) Accuracy on our boxes and sending the corpus off the Mac stay open questions beside it.

## Measurement card

- **Truth:** the owner's 96 (`ocr_card.TRUTH_96`): drafted by Claude Opus 5.5 and Gemini 3.8 Flash, adjudicated by
  the owner where they differed, corrected 2026-10-29. Neither vendor drafted it, so the vendors-against-Mistral
  comparison is untouched by the drafters; but claude-sonnet5.5 (95.9, second in the table) is a relative of the
  Claude Opus 5.5 drafter, and its score can favour that family. Date check uses folder tags only.
- **Selection:** 25 of the 96 by a seeded draw over page ids (seed 4625), never by a tested route or ABBYY text.
  The 96 themselves (`ocr_card.DRAW_96`): every page where Apple Vision (26.6) read fewer than 20 words was
  replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as
  empty, and every comparison with Vision on them is on pages Vision could read.
- **Comparison:** the same original JPEGs (`ocr-panel-cloud/images`, SHA-256 checked) and the same scorer as the
  panel; panel routes are their stored panel replies on these 25. Transkribus read byte-identical copies
  (`transkribus-pack/images`, copied by `r6_spot.py transkribus-pack`), uploaded by hand in the web app.
- **Noise:** n = 25; paired bootstrap intervals above; the 96's rerun floor is 0.49 NES points. Textract's gap to
  Mistral is inside its interval (a tie); Azure's is just outside; Transkribus's is well outside, and its gap to
  Textract is a tie.
- **Scope:** one sample of 25 of the 96 (the owner's scoping), one model per vendor, default settings; the public
  895 half is not run (a line in `execution-plans/paid-runs-deferred.md`). Says nothing about Document AI (no account),
  custom splitters (price read only), Transkribus Text Titan II (not offered on the account; Text Titan I stood
  in) or any Transkribus model trained on this material.
