# Dating: dates on the page that are not in the text (W46.date-image)

Written by `scripts/segbench/date_image.py score`. B test 2 (`execution-plans/processing-review/B-dating.md`): the owner's unprinted-year documents (the year not in the ABBYY text; classes A to D), 122 of the 131 with a confirmed JPEG original of at least one of their first two pages (the other 9 have none; the corpus PDFs are never sent, owner 2026-10-22). Each model was asked to quote every date on the pages, say where it is and what kind, and give the document's own date; once with the images alone and once with the ABBYY text as well. The owner's year is never in the prompt. $0: open weights only (Gemini is W46.date-image-paid).

Measures, per document: **doc year** the document date the model gave equals the owner's year (exact; within one); **on the page** some quoted date has the owner's year written in it (a year the model supplied, not written in the quote, does not count); **not in ABBYY** of those, the quote is not in the ABBYY text either (spacing and punctuation ignored); **Vision agrees** of those, Apple Vision's reading of the same pages has the year or the quote (Vision text is cached for 122 of the 122), a check that the date is really there rather than invented.

## By arm and variant

| arm | variant | parsed | doc year exact | within one | on the page | not in ABBYY | Vision agrees | median s |
|---|---|---|---|---|---|---|---|---|
| Qwen3.6-27B (Sherlock, vLLM, 2,400 px) | image | 122/122 (100%) | 48/122 (39%) | 55/122 (45%) | 52/122 (43%) | 39/52 (75%) | 36/52 (69%) | 17.5 |
| Qwen3.6-27B (Sherlock, vLLM, 2,400 px) | image+text | 122/122 (100%) | 51/122 (42%) | 58/122 (48%) | 54/122 (44%) | 40/54 (74%) | 36/54 (67%) | 19.1 |
| Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px) | image | 122/122 (100%) | 20/122 (16%) | 22/122 (18%) | 39/122 (32%) | 33/39 (85%) | 27/39 (69%) | 12.05 |
| Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px) | image+text | 122/122 (100%) | 21/122 (17%) | 25/122 (20%) | 33/122 (27%) | 25/33 (76%) | 24/33 (73%) | 15.28 |

## By class (doc year exact / on the page)

D has no printed carrier anywhere near it; A had a previous document printing the year (the strict class).

| arm | variant | D | C | B | A | A' |
|---|---|---|---|---|---|---|
| Qwen3.6-27B (Sherlock, vLLM, 2,400 px) | image | 10 / 11 of 17 | 10 / 10 of 31 | 15 / 16 of 35 | 11 / 11 of 32 | 2 / 4 of 7 |
| Qwen3.6-27B (Sherlock, vLLM, 2,400 px) | image+text | 11 / 10 of 17 | 10 / 10 of 31 | 16 / 17 of 35 | 11 / 13 of 32 | 3 / 4 of 7 |
| Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px) | image | 5 / 9 of 17 | 2 / 9 of 31 | 7 / 10 of 35 | 4 / 7 of 32 | 2 / 4 of 7 |
| Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px) | image+text | 6 / 8 of 17 | 4 / 7 of 31 | 8 / 10 of 35 | 3 / 6 of 32 | 0 / 2 of 7 |

## What the page dates are

Of the documents whose owner year was found written on the page (either variant), the first such date: its kind, where it is, and which page. The handwritten share decides whether the handwritten-date reader (B test 8) is worth filing.

- **Qwen3.6-27B (Sherlock, vLLM, 2,400 px)**, 55 documents. Kind: typed 22, printed 19, handwritten 9, stamped 5. Where: dateline 15, other 10, body 9, letterhead 8, margin 8, stamp 5. Page: 1 50, 2 5.
- **Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px)**, 40 documents. Kind: printed 21, typed 10, handwritten 7, stamped 2. Where: letterhead 17, dateline 8, margin 7, body 5, bottom right 2, stamp 1. Page: 1 40.

## Images alone against images with the text

- **Qwen3.6-27B (Sherlock, vLLM, 2,400 px)**, 122 documents: right in both 48, only with images alone 0, only with the text added 3, neither 71.
- **Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px)**, 122 documents: right in both 15, only with images alone 5, only with the text added 6, neither 96.

## Against the owner's own reading of the page

27 of these documents are among the owner's 54 dating cases answered as a date on the document's own page (`date-truth-sets.md`); the owner said what kind it is and whether it is legible.

- **Qwen3.6-27B (Sherlock, vLLM, 2,400 px)**: found the owner's year on the page for 20/27 (74%); kind as the owner gave it for 19 of those 20. Missed: d06 (printed or typed, legible), d18 (printed or typed, legible), d20 (printed or typed, legible), a32 (handwritten, legible), a30 (printed or typed, illegible), a16 (printed or typed, legible), a08 (printed or typed, legible).
  Where the owner's tag differs from the year the owner read on the page (d06 tag 1965, read 1967, d18 tag 1935, read 1936, d20 tag 1935, read 1936, a08 tag 1984, read 1985), the model quoted the year the owner read on 4 of 4.
- **Qwen3-VL 8B, 4-bit MLX (this Mac, 1,400 px)**: found the owner's year on the page for 16/27 (59%); kind as the owner gave it for 14 of those 16. Missed: d13 (printed or typed, legible), d06 (printed or typed, legible), d18 (printed or typed, legible), d20 (printed or typed, legible), a06 (stamped, legible), a32 (handwritten, legible), a30 (printed or typed, illegible), a16 (printed or typed, legible), a07 (handwritten, legible), a08 (printed or typed, legible), a17 (printed or typed, legible).
  Where the owner's tag differs from the year the owner read on the page (d06 tag 1965, read 1967, d18 tag 1935, read 1936, d20 tag 1935, read 1936, a08 tag 1984, read 1985), the model quoted the year the owner read on 3 of 4.

## Look-alike retrieval (B test 6)

Each document takes the year the text rule (`date_traceable.rule_pick`) gives the document whose first page looks most like its own, among the dated documents within 30 either side in the same folder: Apple Vision feature prints of the JPEG originals at 768 px (corpus_pairs's pairing), the print the segmenter features already use, by Euclidean distance. The positional baselines are the same rule's year of the nearest dated document before (what date_traceable propagates) and either side. $0, this Mac.

| class | n | nearest dated before (propagation) | nearest dated either side | most similar page (feature print) | majority of the 3 most similar |
|---|---|---|---|---|---|
| D | 17 | 2 / 7 | 2 / 8 | 1 / 4 | 1 / 3 |
| C | 31 | 3 / 12 | 3 / 12 | 7 / 13 | 7 / 13 |
| B | 35 | 12 / 19 | 17 / 24 | 6 / 14 | 6 / 15 |
| A | 32 | 29 / 30 | 29 / 30 | 11 / 16 | 9 / 14 |
| A' | 7 | 6 / 6 | 3 / 4 | 2 / 4 | 2 / 4 |
| all | 122 | 52 / 74 | 54 / 78 | 27 / 51 | 25 / 49 |

Cells are exact / within one year, of n. 122 of 122 targets have a print; the most similar page is the nearest dated document before on 12 of 121. Its distance in documents from the target: 1 15, 2 8, 3 7, 4 11, 5 8, 6+ 72. Right by look-alike where both positional baselines are wrong: 10; wrong by look-alike where a baseline is right: 44.

## Reading it

(written by hand; a rerun keeps everything below this heading)

**An image pass belongs in the dating pipeline, for the documents whose year is not in the text.** On 52 of the 122
(43%) Qwen3.6-27B quotes a date carrying the owner's year off the page images alone, and three quarters of those quotes
are not in ABBYY's text either. A subagent's eye check of 24 claimed page dates found 23 really there and none invented
(one smeared stamp unsure). On the owner's 27 own-page cases it finds 20, and where the owner's tag and the year the
owner read on the page differ, it quotes the owner's reading on all four. Its document year is exact on 39%, against
0% for the text rule on these documents by construction.

**The text adds almost nothing.** With the ABBYY text as well, the 27B is right on 3 more documents and on none fewer;
the 8B gains 6 and loses 5. The images carry the evidence.

**Few of the dates are handwritten, so the handwritten-date reader (B test 8) is not worth filing.** Of the 27B's 55
found dates, 41 are typed or printed (a dateline, a letterhead, the body), 5 stamped and 9 handwritten; 5 are on page 2.
Most of what ABBYY missed is ordinary type in places it does not read well, which a general VLM reads. Nine handwritten
dates across 131 documents do not pay for annotating 300-500 pages and training a detector and recogniser.

**The Mac's 16 GB model is much weaker.** Qwen3-VL 8B 4-bit at 1,400 px finds the owner's year on the page for 32%
(16 of the owner's 27 cases) but gives it as the document's year for only 16%: it often quotes the right date and then
picks another one. Used as a quote source for the chooser, with the year picked by the rule or the 2B date model, it is
worth more than its document-year figure. The 27B's figures need the 32 GB tier (or the cluster, or the gateway's
Gemini, W46.date-image-paid). Images at 1,400 px and 4-bit weights are both part of the gap; neither was separated here.

**Look-alike retrieval is worse than position** (27 exact against 52 for the nearest dated document before) and helps
only class C; it is not a route.

The arm that ran is Qwen3.6-27B, not the Qwen3-VL 235B the item names: the owner's Sherlock session packed the 27B,
whose server was already up. A 235B run would only say how much of the 27B's 57% miss a bigger reader recovers.
