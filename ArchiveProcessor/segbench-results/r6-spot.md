# W46.r6-spot — Azure Document Intelligence and AWS Textract on 25 of the 96

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

Paired against Mistral OCR 4.1 (10,000 bootstrap rounds): Azure −2.9 NES points (interval −6.3 to −0.2);
Textract layout −5.8 (−13.4 to +1.5, a tie at n = 25). Textract's LAYOUT ordering adds 3.2 points over its raw
line order, so its reading order is part of the gap.

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
  panel; panel routes are their stored panel replies on these 25.
- **Noise:** n = 25; paired bootstrap intervals above; the 96's rerun floor is 0.49 NES points. Textract's gap to
  Mistral is inside its interval (a tie); Azure's is just outside.
- **Scope:** one sample of 25 of the 96 (the owner's scoping), one model per vendor, default settings; the public
  895 half is not run (a line in `execution-plans/paid-runs-deferred.md`). Says nothing about Document AI (no account),
  custom splitters (price read only) or Transkribus (hand-upload pack, scored when the owner exports it).
