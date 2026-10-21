# Dating: the classes A to D and the gap audit's scorers on every cached answer (W46.fix-date-truth)

Written by `scripts/segbench/date_truth.py score` from the cached replies of the W41 date-tagging sample (300 documents, the app's prompt with three neighbours at 300 characters; `date-tagging.md`). No new call, $0. The scorers are `date_scorers.py` (gap audit §4 fix 9, B-dating.md §3-4).

## The classes

Of the 250 year-tagged documents, 119 print their owner year in the text sent. The other 131 are classed by where the nearest document printing the same owner year sits in folder order: A strict (the previous document) 33, A' chained (back through unprinted same-year documents, within three) 7, B near (within three either side, not A or A') 35, C far (four or more away) 35, D none in the folder 21. A + A' + B = 75, the audit's "within three".

The owner's sheet (private, `date-tagging/cases/` in the bench cache) asks, for the A and D documents, where the year came from; W46.fix-date-truth-score turns the answers into the relation and image-extraction truth sets. The classes here are structural (tags and order); they are not yet truth.

## Year accuracy by class

Left out of every table: qwen3.5-4b, qwen3.6-27b, qwen3.6-35b-a3b, whose replies give no year on most documents (the thinking runs, which all ran to the 512-token cap; `date-tagging.md`). They are in `date-truth.json`.

Exact and within one year, every row in the denominator (a reply with no year is a miss). Invalid = replies the app gets no year from.

| model | invalid | in text exact | A exact | A' exact | B exact | C exact | D exact | not in text exact |
|---|---|---|---|---|---|---|---|---|
| gemini-3.8-flash | 0.0% (0/300) | 97.5% (116/119) | 81.8% (27/33) | 71.4% (5/7) | 62.9% (22/35) | 45.7% (16/35) | 61.9% (13/21) | 63.4% (83/131) |
| qwen3-vl-8b | 0.0% (0/300) | 94.1% (112/119) | 51.5% (17/33) | 71.4% (5/7) | 31.4% (11/35) | 17.1% (6/35) | 28.6% (6/21) | 34.4% (45/131) |
| qwen3.5-4b-nothink | 0.0% (0/300) | 95.8% (114/119) | 60.6% (20/33) | 57.1% (4/7) | 31.4% (11/35) | 11.4% (4/35) | 23.8% (5/21) | 33.6% (44/131) |
| qwen3.6-27b-nothink | 0.0% (0/300) | 97.5% (116/119) | 66.7% (22/33) | 71.4% (5/7) | 40.0% (14/35) | 20.0% (7/35) | 33.3% (7/21) | 42.0% (55/131) |
| qwen3.6-35b-a3b-nothink | 1.7% (5/300) | 96.6% (115/119) | 57.6% (19/33) | 71.4% (5/7) | 34.3% (12/35) | 14.3% (5/35) | 33.3% (7/21) | 36.6% (48/131) |

| model | in text within 1 | A within 1 | A' within 1 | B within 1 | C within 1 | D within 1 | not in text within 1 |
|---|---|---|---|---|---|---|---|
| gemini-3.8-flash | 99.2% (118/119) | 93.9% (31/33) | 100.0% (7/7) | 88.6% (31/35) | 91.4% (32/35) | 90.5% (19/21) | 91.6% (120/131) |
| qwen3-vl-8b | 96.6% (115/119) | 66.7% (22/33) | 71.4% (5/7) | 42.9% (15/35) | 34.3% (12/35) | 33.3% (7/21) | 46.6% (61/131) |
| qwen3.5-4b-nothink | 100.0% (119/119) | 75.8% (25/33) | 85.7% (6/7) | 57.1% (20/35) | 48.6% (17/35) | 38.1% (8/21) | 58.0% (76/131) |
| qwen3.6-27b-nothink | 99.2% (118/119) | 78.8% (26/33) | 85.7% (6/7) | 68.6% (24/35) | 60.0% (21/35) | 61.9% (13/21) | 68.7% (90/131) |
| qwen3.6-35b-a3b-nothink | 99.2% (118/119) | 78.8% (26/33) | 85.7% (6/7) | 62.9% (22/35) | 60.0% (21/35) | 57.1% (12/21) | 66.4% (87/131) |

## Tolerance curve on the unprinted years

Share of the not-in-text documents within k years of the owner's year (B33's tolerance curve).

| model | k=0 | k=1 | k=2 | k=3 | k=4 | k=5 |
|---|---|---|---|---|---|---|
| gemini-3.8-flash | 63.4% (83/131) | 91.6% (120/131) | 94.7% (124/131) | 96.9% (127/131) | 97.7% (128/131) | 98.5% (129/131) |
| qwen3-vl-8b | 34.4% (45/131) | 46.6% (61/131) | 52.7% (69/131) | 55.0% (72/131) | 58.0% (76/131) | 61.1% (80/131) |
| qwen3.5-4b-nothink | 33.6% (44/131) | 58.0% (76/131) | 64.9% (85/131) | 71.8% (94/131) | 72.5% (95/131) | 74.8% (98/131) |
| qwen3.6-27b-nothink | 42.0% (55/131) | 68.7% (90/131) | 77.9% (102/131) | 81.7% (107/131) | 87.0% (114/131) | 90.8% (119/131) |
| qwen3.6-35b-a3b-nothink | 36.6% (48/131) | 66.4% (87/131) | 74.0% (97/131) | 77.9% (102/131) | 79.4% (104/131) | 82.4% (108/131) |

## Owner-inferred dates as intervals

Decade tags scored as the decade's ten years (HDC distance from the interval); `year + Date Uncertain` tags scored as the year plus or minus one, since the owner's year is itself an estimate.

| model | decade: inside | decade: mean distance (yrs, rows with a year) | estimated year: within ±1 | mean distance beyond ±1 |
|---|---|---|---|---|
| gemini-3.8-flash | 68.0% (34/50) | 3.04 (50) | 86.0% (43/50) | 0.52 (50) |
| qwen3-vl-8b | 46.0% (23/50) | 8.26 (50) | 36.0% (18/50) | 7.64 (50) |
| qwen3.5-4b-nothink | 48.0% (24/50) | 5.62 (50) | 58.0% (29/50) | 3.58 (50) |
| qwen3.6-27b-nothink | 58.0% (29/50) | 3.78 (50) | 62.0% (31/50) | 1.60 (50) |
| qwen3.6-35b-a3b-nothink | 54.0% (27/50) | 4.06 (48) | 66.0% (33/50) | 2.06 (48) |

## `Date Uncertain` as two error rates

Owner-certain (a year, with or without a month, no `Date Uncertain`) flagged uncertain by the reply, and owner-uncertain (`year + Date Uncertain`) flagged certain. A reply that never sets the flag scores 0% on the first and 100% on the second, which plain agreement hides at about 80%.

| model | certain → flagged (all) | uncertain → not flagged (all) | certain → flagged (not in text) | uncertain → not flagged (not in text) |
|---|---|---|---|---|
| gemini-3.8-flash | 31.5% (63/200) | 12.0% (6/50) | 69.8% (60/86) | 4.4% (2/45) |
| qwen3-vl-8b | 1.0% (2/200) | 96.0% (48/50) | 2.3% (2/86) | 95.6% (43/45) |
| qwen3.5-4b-nothink | 14.0% (28/200) | 54.0% (27/50) | 30.2% (26/86) | 48.9% (22/45) |
| qwen3.6-27b-nothink | 26.0% (52/200) | 36.0% (18/50) | 59.3% (51/86) | 28.9% (13/45) |
| qwen3.6-35b-a3b-nothink | 30.0% (60/200) | 22.0% (11/50) | 64.0% (55/86) | 15.6% (7/45) |

## Split-conformal intervals at 90%

The replies give a point year, so the interval is the year widened by the calibration half's quantile of |error| (FermiEval's rank ceil((1-α)(n+1))), tested on the other half and swapped (seed 46). A stratum needs 15 documents in each half (B47), so A' and D cannot be scored alone and are pooled as A+A' and C+D. A reply with no year is uncovered and left out of the width. q is the widening in years for each half; Winkler is width plus 2/α times any miss.

| model | stratum | n | q | coverage | width | Winkler |
|---|---|---|---|---|---|---|
| gemini-3.8-flash | in text | 119 | 0/0 | 97.5% (116/119) | 0.0 | 0.7 |
| gemini-3.8-flash | A+A' | 40 | 1/1 | 95.0% (38/40) | 2.0 | 7.5 |
| gemini-3.8-flash | B | 35 | 9/2 | 94.3% (33/35) | 11.2 | 16.3 |
| gemini-3.8-flash | C+D | 56 | 1/3 | 92.9% (52/56) | 4.0 | 6.9 |
| gemini-3.8-flash | not in text | 131 | 1/2 | 92.4% (121/131) | 3.0 | 7.7 |
| gemini-3.8-flash | all year-tagged | 250 | 1/1 | 95.2% (238/250) | 2.0 | 4.8 |
| qwen3-vl-8b | in text | 119 | 0/0 | 94.1% (112/119) | 0.0 | 6.9 |
| qwen3-vl-8b | A+A' | 40 | 19/21 | 92.5% (37/40) | 40.0 | 70.5 |
| qwen3-vl-8b | B | 35 | 30/28 | 97.1% (34/35) | 58.1 | 59.2 |
| qwen3-vl-8b | C+D | 56 | 38/34 | 94.6% (53/56) | 72.0 | 87.0 |
| qwen3-vl-8b | not in text | 131 | 19/28 | 88.5% (116/131) | 46.9 | 76.7 |
| qwen3-vl-8b | all year-tagged | 250 | 13/20 | 91.6% (229/250) | 33.0 | 58.3 |
| qwen3.5-4b-nothink | in text | 119 | 0/0 | 95.8% (114/119) | 0.0 | 0.8 |
| qwen3.5-4b-nothink | A+A' | 40 | 12/14 | 95.0% (38/40) | 26.0 | 31.5 |
| qwen3.5-4b-nothink | B | 35 | 39/23 | 97.1% (34/35) | 62.5 | 71.6 |
| qwen3.5-4b-nothink | C+D | 56 | 29/17 | 89.3% (50/56) | 46.0 | 61.4 |
| qwen3.5-4b-nothink | not in text | 131 | 15/18 | 91.6% (120/131) | 33.0 | 48.5 |
| qwen3.5-4b-nothink | all year-tagged | 250 | 7/14 | 91.2% (228/250) | 21.0 | 40.1 |
| qwen3.6-27b-nothink | in text | 119 | 0/0 | 97.5% (116/119) | 0.0 | 1.0 |
| qwen3.6-27b-nothink | A+A' | 40 | 8/4 | 90.0% (36/40) | 12.0 | 17.0 |
| qwen3.6-27b-nothink | B | 35 | 20/20 | 100.0% (35/35) | 40.0 | 40.0 |
| qwen3.6-27b-nothink | C+D | 56 | 15/4 | 89.3% (50/56) | 19.0 | 35.4 |
| qwen3.6-27b-nothink | not in text | 131 | 6/5 | 91.6% (120/131) | 11.0 | 22.5 |
| qwen3.6-27b-nothink | all year-tagged | 250 | 2/4 | 90.0% (225/250) | 6.0 | 16.6 |
| qwen3.6-35b-a3b-nothink | in text | 119 | 0/0 | 96.6% (115/119) | 0.0 | 1.0 |
| qwen3.6-35b-a3b-nothink | A+A' | 40 | 9/21 | 90.0% (36/40) | 30.3 | 39.5 |
| qwen3.6-35b-a3b-nothink | B | 35 | ∞/20 | 97.1% (34/35) | 40.0 | 40.0 |
| qwen3.6-35b-a3b-nothink | C+D | 56 | 19/11 | 91.1% (51/56) | 30.1 | 40.7 |
| qwen3.6-35b-a3b-nothink | not in text | 131 | 14/10 | 90.1% (118/131) | 24.0 | 34.8 |
| qwen3.6-35b-a3b-nothink | all year-tagged | 250 | 5/7 | 91.6% (229/250) | 12.0 | 24.1 |

## Evidence validity

No cached reply cites evidence (0 rows with any): the app's prompt does not ask for it. `date_scorers.evidence_check` is ready for W46.date-traceable's prompt, which asks for the cited neighbour and a quote: the neighbour must be in the context given, the quote a spacing-tolerant substring of its text, and the quote must carry the year; a located region must contain a date string with that year. A right year with failed evidence counts as unsupported.
