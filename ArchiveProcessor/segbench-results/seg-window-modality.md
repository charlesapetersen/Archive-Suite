# W46.seg-window-modality — window size, text-only windows and self-voting, open arms

A04 (Multi-Split) makes two claims on clean TABME++ scans: window size matters little to a strong model and a lot to
a weak one, and images add nothing once the neighbouring page's text is in view. This item tests both on the owner's
photographs with the trained Qwen3.5 2B (the laptop route), and adds a third test: whether a model that votes with
itself over several window placements and prompts does better than it does alone.

- **Sweep.** The 2B (`fs-seg-2b`) on the three development boxes (Dean, Deaver, Herrnstein; 551 pages, 518 of them
  document pages), at K = 3, 5, 7 and 10 pages a window and the whole folder, each with images and text (`it`, the
  bench's request) and with the OCR text alone (`t`). A K-page window steps (K - 1) // 2 pages, so every gap is judged
  about twice at every K.
- **Vote.** The 2B, the trained 4B (`fs-seg-4b`) and the Qwen3.5 27B teacher (FP8) on Lincoln (public, 261 pages) and
  the two locked test boxes (Stanton 250, RG165 113; 330 document pages), six runs each: window offsets 0, 1 and 2
  pages by two prompts (`l1`, the bench's request; `w1`, method_window's first wording). The vote is the six runs'
  majority on each gap, a 3-3 tie going to the mean P(new).

Everything was fixed before any answer (`seg_window_modality.py`'s docstring); nothing was chosen on the test boxes.
Owner boxes are scored with truth photos, Lincoln with the model's own. Run on Sherlock, one L40S per model, vLLM
0.31.0, batch 20261029-102545: 6,110 requests in six jobs, 2.6 GPU-hours against the 3.5 estimated (teacher 1 h 50,
2B 25 min, 4B 22 min). Scores: `seg-window-modality.json` (`seg_window_modality.py score`; `pooled` holds the figures
below). No money was spent.

## Window size and text-only (the 2B, development boxes)

Pages in an exact document, pooled over the three boxes; boundary F1 and false splits / merges in brackets.

| K | Images and text | Text only | Text-only cost |
|---|---|---|---|
| 3 | 87.6% (96.6; 12 / 8) | 77.8% (93.8; 16 / 20) | -9.8 pts |
| 5 | 88.4% (96.6; 11 / 9) | 83.8% (94.1; 20 / 15) | -4.6 pts |
| **7** | **90.9%** (97.3; 6 / 10) | 82.6% (94.2; 15 / 19) | -8.3 pts |
| 10 | 89.2% (96.4; 8 / 13) | 69.5% (90.2; 20 / 36) | -19.7 pts |
| Whole folder | 63.7%, Deaver and Herrnstein only (83.0; 11 / 44) | 72.4% (89.5; 22 / 38) | — |

Per box, images and text at K = 3 / 5 / 7 / 10: Dean 84.7 / 88.3 / 93.9 / 88.8%, Deaver 87.2 / 87.2 / 90.1 / 90.8%,
Herrnstein 91.2 / 89.5 / 88.4 / 88.4%. Text only: Dean 86.2 / 88.3 / 85.7 / 58.7%, Deaver 71.6 / 78.7 / 75.2 / 73.0%,
Herrnstein 73.5 / 82.9 / 85.1 / 78.5%. Whole folder, images / text: Dean — / 78.6%, Deaver 42.6 / 62.4%,
Herrnstein 80.1 / 73.5%.

- **Window size is flat for the 2B from K = 3 to 10, with images.** The four sizes lie within 3.3 points pooled and no
  size wins on every box (Herrnstein is best at K = 3). That is inside the spread a window placement alone makes on
  the test boxes (below). K = 7 is best pooled and is the size the 2B was trained on.
- **The whole folder collapses.** With images the 2B merges whole runs of documents (44 false merges on two boxes),
  and 2 of its 21 folder units, Dean's 25- and 57-page runs, came back unparseable twice (the page list did not match
  the request), so Dean's image cell is not scored. Only 9 of 19 folders came out perfect, against 14 of 24 at K = 7.
- **Images are not redundant on photographs.** Text-only costs 4.6 to 19.7 points at every window size and on every
  box but Dean at K = 3 and 5, with more splits and more merges at once. A04's second claim does not carry to this model
  on this material. Read it with its limit: the 2B was trained on image windows, so text-only also puts it off its
  training shape. Whether a strong model is as insensitive to the images as A04 says is the paid item's question.

## Voting (the three models, test boxes and Lincoln)

Pages in an exact document. "Default" is offset 0 with `l1`, the request the bench always sends.

| Model | Pool | Default | Mean of the six single runs | Single runs, lowest – highest | Vote of six | Offsets only (l1) | Prompts only (offset 0) |
|---|---|---|---|---|---|---|---|
| 2B | Stanton + RG165 | 81.2% | 77.7% | 74.8 – 81.2% | 80.6% | 77.0% | 80.0% |
| 4B | Stanton + RG165 | 79.1% | 78.2% | 72.7 – 81.8% | 79.7% | 80.3% | 79.7% |
| 27B teacher | Stanton + RG165 | 83.0% | 80.3% | 76.4 – 83.0% | 82.1% | 82.4% | 82.7% |
| 2B | Lincoln | 36.4% | 40.1% | 31.0 – 49.0% | 47.5% | 34.5% | 45.2% |
| 4B | Lincoln | 49.4% | 48.2% | 45.6 – 51.3% | 51.7% | 52.9% | 58.2% |
| 27B teacher | Lincoln | 40.6% | 43.2% | 38.7 – 47.9% | 42.9% | 39.1% | 47.9% |

- **On the owner's test boxes the vote does not beat the default run** for any model (2B -0.6, 4B +0.6, teacher -0.9
  points). It beats the average single run by 1.5 to 2.9 points, which is what it is for: it removes the luck of one
  window placement. Boundary F1 moves by under a point either way.
- **A single run's placement and prompt alone move a test-box score by 6 to 9 points** (the lowest-to-highest column),
  and a byte-identical rerun of the default request moved Stanton's 2B from 73.3% (FarmShare, 2026-10-18) and 74.1%
  (seg-context's Sherlock rerun) to 76.5% here, Deaver's K = 7 from 88.7% to 90.1%, and Lincoln's 2B from 34.9% to
  36.4%. Differences of about 3 points pooled between arms on these boxes are not findings.
- **Lincoln gains from the second prompt, not from voting.** `w1` cuts the false splits on Lincoln's long manuscripts
  (the 2B's three `w1` runs score 42.1, 48.7 and 49.0% against `l1`'s 31.0 to 36.4%; the teacher's 44.4 to 47.9%
  against 38.7 to 42.5%). On the owner's test boxes `w1` is no better (2B 79.4% against 81.2% at offset 0). It is a
  lead on one public box, not a reason to change the prompt.

## Recommendations

1. **The local route keeps K = 7 with images.** Nothing smaller or larger is better, and the whole folder is not a
   route for the 2B.
2. **A text-only 2B window is not a route.** Skipping the vision encoder would save time on the laptop, but it costs
   about 8 points at K = 7 on the development boxes.
3. **No self-voting for the local route or the teacher labeller.** Six runs cost six times the compute (the 2B takes
   about 18 s a window on the M3 Pro) and land no higher than the default single run on the test boxes.
4. **W46.seg-window-modality-paid keeps its size question open.** The 2B is flat in K, so Gemini's K = 3, 5 and 10 arms
   can run on the 150-page subset; the text-only arm should keep the full 551 development pages, because the 2B is
   not flat in modality and the paid item is what says whether a strong model is. That item's session decides its
   own arms within its $8 cap.

## Speed on one L40S (concurrency 16)

Teacher 1,260 vote windows in 6,350 s (5.0 s a window); 4B 1,260 in 1,161 s (0.9 s); 2B 1,260 in 583 s (0.5 s); the
2B's sweep 2,288 requests in 642 s; its 42 whole-folder requests in 91 s (mean prompt 21,670 tokens, the longest about
64,000). These are cluster throughput figures, not the laptop route's.
