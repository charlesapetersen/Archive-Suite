# W46.seg-window-modality-paid — Gemini 3.7 Flash: window size and text-only windows

The paid half of W46.seg-window-modality (`seg-window-modality.md`), whose open arms found the trained 2B flat in window size with images and 4.6 to 19.7 points worse on text alone. This asks the same of a strong model: Gemini 3.7 Flash through the Stanford AI API gateway, low reasoning, temperature 0, the bench's g1 request (1600 px images, cached Apple Vision text), on the owner's development boxes. Arms, settings and the subset were fixed in `seg_window_gateway.py`'s docstring before any answer; the K = 7 image arm is the control every other arm is read against (SEG-9: 3.7 is never compared with the cached 3.8 figures, which are shown only for reference). Scores: `seg-window-gateway.json` (`seg_window_gateway.py score`).

Pages in an exact document, with truth photos; boundary F1 and false splits / merges in brackets. The paired column is the arm less the control, in points, with a 95% paired bootstrap interval over the truth's documents.

## Images against text alone (K = 7, all 551 pages)

| Arm | Dean + Deaver + Herrnstein | Less the control |
|---|---|---|
| Gemini 3.7, images and text (control) | 92.3% (97.3; 9 / 7) | — |
| Gemini 3.7, text only | 89.6% (97.6; 6 / 8) | -2.7 (-9.5 to +1.6) |
| Gemini 3.8, images and text (cached, reference) | 90.7% (97.6; 7 / 7) | -1.5 (-8.3 to +2.8) |

For the 2B on the same pages (`seg-window-modality.json`): 90.9% with images, 82.6% text only.

## Window size on Deaver (149 pages)

| K | Images and text | Less K = 7 | Text only | Text less images |
|---|---|---|---|---|
| 3 | 92.2% (98.2; 2 / 1) | +0.0 (-10.4 to +8.6) | 93.6% (97.6; 2 / 2) | +1.4 (-7.4 to +11.7) |
| 5 | 93.6% (97.6; 3 / 1) | +1.4 (-5.8 to +9.0) | 95.0% (98.2; 1 / 2) | +1.4 (-4.3 to +7.5) |
| 7 | 92.2% (97.1; 4 / 1) | — | 93.6% (97.6; 2 / 2) | +1.4 (-4.3 to +7.4) |
| 10 | 92.2% (97.1; 4 / 1) | +0.0 (-7.0 to +6.9) | 93.6% (97.6; 2 / 2) | +1.4 (-2.8 to +6.2) |
| Whole folder | 88.7% (95.5; 8 / 0) | -3.5 (-11.3 to +3.6) | not run | — |

Gemini 3.8 on Deaver for reference: 97.9% (99.4; 0 / 1) at K = 7, 93.6% (98.8; 1 / 1) whole folder.

## Calls and cost

| Arm | Calls | Parsed | Input tokens | Output tokens (reasoning) | Cost estimate | Mean seconds |
|---|---:|---:|---:|---:|---:|---:|
| k7-it | 187 | 187 | 2,172,566 | 77,557 (1,221) | $1.920 | 6.7 |
| k7-t | 187 | 187 | 800,477 | 77,115 (0) | $0.890 | 4.6 |
| k3-it | 148 | 148 | 946,923 | 25,962 (462) | $0.808 | 4.8 |
| k5-it | 73 | 72 | 697,028 | 21,420 (395) | $0.642 | 5.7 |
| k10-it | 37 | 37 | 651,943 | 20,691 (0) | $0.567 | 8.7 |
| folder-it | 5 | 5 | 240,468 | 6,034 (0) | $0.203 | 14.7 |
| k3-t | 148 | 148 | 473,167 | 26,610 (0) | $0.455 | 2.9 |
| k5-t | 72 | 72 | 312,057 | 22,341 (0) | $0.318 | 4.1 |
| k10-t | 37 | 37 | 261,642 | 21,132 (0) | $0.275 | 5.3 |

Item total $6.0765 of the $8.00 cap, at list token rates ($0.75 / $3.75 per million, reasoning included; the gateway offers no batch route); the gateway's own figure $6.0379 on 893 of 894 calls, 1.00 times the estimate on them. Every attempt is counted, failed ones included.

## Findings

- **Text alone costs Gemini little at K = 7, unlike the 2B.** Over the 551 pages the text-only arm is 2.7 points below the image control (89.6% against 92.3%; interval -9.5 to +1.6), a tie at this size, with the same boundary F1 (97.6 against 97.3: three fewer false splits, one more merge). The loss sits on one box: Dean drops from 93.4% to 85.2%, Herrnstein is level at 91.2% and Deaver gains 1.4 points. The 2B lost 8.3 points on the same pages. A04's claim, that the neighbouring text makes the images redundant, comes close to holding for a strong model on these photographs and does not hold for the small one. Text only costs 46% of the image arm ($0.89 against $1.92 for the 187 windows) and answers in 4.6 s against 6.7 s.
- **Window size is flat for Gemini too.** On Deaver, K = 3, 5, 7 and 10 lie within 1.4 points of each other, with images (92.2-93.6%) and without (93.6-95.0%): one document or less, every interval spanning zero. K = 7 and K = 10 are the cheapest image windows on Deaver ($0.56 and $0.57, against $0.64 at K = 5, which carries one unsettled 502's reservation, and $0.81 at K = 3), since smaller windows send each page more often.
- **The whole folder is no better.** Gemini 3.7's whole folders on Deaver put 88.7% of pages in the exact document, 3.5 points under K = 7 (interval -11.3 to +3.6), with twice the false splits (8 against 4), for $0.20 against $0.56. Gemini 3.8's whole folders were also below its windows on Deaver (93.6% against 97.9%), though level over the three boxes.
- **3.7 and 3.8 differ box by box, not overall (SEG-9).** Pooled, the cached 3.8 windows are 1.5 points under 3.7's (a tie); on Deaver 3.8 is 5.7 points higher (interval +1.3 to +11.8), on Dean 3.7 is 8.2 points higher. A 3.8 figure is not a stand-in for 3.7's on any one box, which is why every arm here is read against the 3.7 control.

## What this means

1. **The cloud route keeps K = 7 with images.** No size beats it, none is cheaper, and the whole folder is not better.
2. **A text-only cloud window is a lead for a cheaper tier, not a default.** It roughly halves the token cost and lands within noise over three boxes, but its point estimate is a loss, all on one box. Phase 4 (W46.review-phase4) weighs it against the cost profiles; a test-box run would be needed before it ships.
3. **The local 2B keeps its images** (seg-window-modality.md): the gap between the two models is the finding.

## Measurement card

- **Truth.** The owner-ruled development boxes Dean, Deaver and Herrnstein (no unsure gaps), with truth photos, as every development-box figure is. No drafter's or tested route's labels enter the truth.
- **Selection.** Every page of the three development boxes for K = 7; Deaver whole for the other sizes, chosen as the box nearest the 150-page subset seg-window-modality.md recommended, before any answer. Arms and settings fixed in the docstring before any call; no ABBYY text.
- **Comparison.** One model (Gemini 3.7 Flash), one route, one prompt family, temperature 0, low reasoning, in one collection; each arm is read against the K = 7 image control on the same pages. Text-only changes only the images and one paragraph. The whole-folder arm uses JPEG quality 45 and the wh1 prompt, and the 3.8 figures are a different model on a different route, reference only.
- **Noise.** One run per arm (n = 518 document pages, 318 truth documents, on the three boxes; 141 pages, 89 documents on Deaver). Paired bootstrap intervals over truth documents cover document sampling, not rerun variation; the rerun floor is 1.4-3.2 points a box (SEG-10), so a gap inside it is a tie. The resampling unit was changed from folder runs after the first score: Deaver has five, too few to resample (the JSON keeps those intervals as by_folder_run). Deaver's documents are 1-6 pages, so one boundary moves Deaver by up to about 4 points.
- **Scope.** Whether a strong cloud model needs the images at K = 7 on the owner's photographs, and whether its window size matters on one box. It does not set the app's cloud window (that is options.md's and Phase 4's), does not rank 3.7 against 3.8, and the size sweep on one 149-page box cannot separate sizes within a few points.

