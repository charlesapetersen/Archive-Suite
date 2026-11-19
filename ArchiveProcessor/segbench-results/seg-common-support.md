# Segmentation on common truth support — W46.seg-common-support

Offline rescore of cached answers; $0, no model or upload, every rule/level kept frozen. The two unknown RG165 gaps remove five of 330 document pages: every route ranks on the same 325. Checking costs still cover all 363 photographed pages and all 315 document gaps.

| route | old conditional upper (not ranking) | common support, no checking | ideal checking | checks/100 photographed pages |
|---|---:|---:|---:|---:|
| Full manual | — | — | 100.0% | 86.8 |
| Claude only | 89.1% | 88.9% | 98.5% | 10.2 |
| Gemini only | 87.6% | 87.4% | 100.0% | 25.3 |
| ChatGPT only | 90.3% | 90.2% | 100.0% | 79.1 |
| Claude and ChatGPT together | 90.3% | 90.2% | 98.5% | 10.2 |
| GLM-5.3 Flash only (budget) | 83.0% | 82.8% | 96.9% | 33.1 |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | 79.7% | 79.4% | 98.8% | 78.8 |
| Gemini only, text alone (budget) | 87.9% | 87.7% | 98.5% | 29.2 |

### Truth support and unknown-gap bounds

Ranked exactness uses the same **325 of 330 document pages** for every row: only whole documents touching none of the 2 unknown gaps. Those gaps are neither right nor wrong. Checking work and money still count all photographed pages and every flagged unknown gap. After-checking figures assume perfect correction of known gaps; they are not observed human accuracy.

The bounds below use **all document pages**. The upper is conditional on each route being right at every unknown gap, so it is an optimistic, route-specific figure and does not rank routes. These are truth-ambiguity bounds, not sampling intervals or offset ranges.

| route | no checking: lower–conditional upper | ideal checking: lower–conditional upper |
|---|---:|---:|
| Full manual | — | 98.5%–100.0% |
| Claude only | 87.6%–89.1% | 97.0%–98.5% |
| Gemini only | 86.1%–87.6% | 98.5%–100.0% |
| ChatGPT only | 88.8%–90.3% | 98.5%–100.0% |
| Claude and ChatGPT together | 88.8%–90.3% | 97.0%–98.5% |
| GLM-5.3 Flash only (budget) | 81.5%–83.0% | 95.5%–97.0% |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | 78.2%–79.7% | 97.3%–98.8% |
| Gemini only, text alone (budget) | 86.4%–87.9% | 97.0%–98.5% |

## Other cluster routes, from cached additive counts

These no-checking figures use the same 325 document pages. Other segment metrics in their old reports remain conditional diagnostics, with no fixed-truth ranking claim.

| route | common support | all-document lower | conditional upper |
|---|---:|---:|---:|
| window-or-fs-seg-2b | 79.4% | 78.2% | 79.7% |
| window-or-fs-seg-4b | 82.8% | 81.5% | 83.0% |
| window-or-fs-qwen3.5-27b | 81.2% | 80.0% | 81.5% |

## Offset floors and picks

On this same support g1 spans 2.462 points (rounded 2.5, previously 2.4), g2 5.231 (rounded 5.2). The owner's per-pair construction is unchanged: twice the larger own range, borrowing g1 only when absent. Thus unmeasured pairs used 5.0 points, g2 pairs 10.4, when this item shipped. That floor is superseded: the paired rule (seg-pair-ties.md, W46.seg-truth-audit, with the students' rerun floor since W46.p16-seg-tie-floor) now decides a tie, and both pairs that move below tie under it, so both picks stand (W46.p16-score-hygiene). The numerical borrowing change follows the common denominator; it is not a new tie policy. Documented profiles keep their picks. Two move on one 16-page gap: text alone has 285 of 325 exact, GLM-5.3 Flash and the cluster 4B 269 each, 4.9 points against the 5.0 floor (on 330 pages, 4.85 against 4.8). A Gemini plus OpenRouter key now picks GLM-5.3 Flash, a cluster plus a Gemini key the cluster 4B; the cheaper route wins the tie. The gap is exactly twice g1's 8-page spread, so the move follows the denominator and rounding, not a measured change (13-profile-tests.md; SettingsSolverTestDriver).

## Measurement card

- **Truth.** Owner-ruled Stanton and RG165, including the eight corrections and two unknowns recorded by W46.seg-truth-owner-fixes; truth photo labels.
- **Selection.** The same frozen whole test boxes, not selected by these answers.
- **Comparison.** One fixed common document support for every route and every offset; own frozen review rules/levels, original prompts/models retained and disclosed in options.md.
- **Noise.** Truth ambiguity bounds are distinct from offset placement ranges; neither measures fresh material or human correction accuracy. No level refitted here.
- **Scope.** Repairs the ranked estimand, not truth, predictions or trained models. Gemini 3.8 still borrows Gemini 3.7 evidence; Claude w1 has a different magazine rule.

