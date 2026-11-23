# What the handwriting switch adds with the pre-flag

W46.p18-mixed-switch-score · Pass 18 P18-5 · See `kind-atrium.md` §5 for the standalone detector.

In the saved-page replay, 1,449/2,000 pages met the typed/printed and confidence rules. The downloaded pre-flag would make **412 of those pages candidates for the handwriting reader** (119 printed, 293 typewritten), or 28.43% of eligible pages and 20.60% of the draw. The handwriting kind alone chose 157 pages, and the union chose 569. Each choice can replace the page’s usual reader.

The hand-only labels would yield 221 existing choices and 509 additions (730 total). Replaying the form override and confidence floor (0.80) excludes 1 form and 96 low-confidence pages from the additions.

## Estimates and their support

Mixed means handwriting on typed or printed text, including a signature. Precision is the share of called pages that are mixed. In the kind-only and combined rows, a correctly routed wholly handwritten page still counts outside this mixed-page target. Recall is the share of mixed pages called, either in the whole draw or among eligible pages as named.

Covered estimates use the original population-to-check weights within each of the fixed disagreement patterns and clean controls, plus weight 1 for the 39-page census. The 11 top-ups constrain exact bounds. The weighted covered frame is 1,881 pages before eligibility, with 170 owner checks in the full draw. Each mixed-page numerator and recall denominator uses those weights on its own domain. Precision uses the exact count of called pages in the covered domain because eligibility can vary within a pattern.

| Rule | Full calls | Checked mixed hits / calls | Mixed / judged | Covered pages | Weighted mixed hits | Weighted mixed pages | Covered precision | Covered recall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ATRIUM alone | 563 | 103/129 | 121/170 | 1,881 | 393.10 | 650.90 | 69.82% | 60.39% |
| Kind-only handwriting pick | 157 | 23/26 | 121/170 | 1,881 | 43.50 | 650.90 | 94.57% | 6.68% |
| Switch additions, all-page recall | 412 | 49/69 | 121/170 | 1,881 | 295.18 | 650.90 | 71.65% | 45.35% |
| Switch additions, eligible-page recall | 412 | 49/69 | 53/88 | 1,449 | 295.18 | 478.98 | 71.65% | 61.63% |
| Kind and switch together | 569 | 72/95 | 121/170 | 1,881 | 338.68 | 650.90 | 73.95% | 52.03% |

**Point-completion sensitivity.** Hold the covered weighted counts fixed and vary missing truth in the omitted strata. “Hand not mixed” treats unchecked agreed-handwritten pages as wholly handwritten. “Unrestricted” leaves their truth open too. These ranges are completion bounds, with no confidence level.

| Rule | Precision, hand not mixed | Recall, hand not mixed | Precision, unrestricted | Recall, unrestricted |
|---|---:|---:|---:|---:|
| ATRIUM alone | 69.82%–69.82% | 59.12%–60.39% | 69.82%–69.82% | 51.06%–60.39% |
| Kind-only handwriting pick | 27.71%–32.80% | 6.62%–7.82% | 27.71%–98.41% | 6.60%–20.28% |
| Switch additions, all-page recall | 71.65%–71.65% | 44.40%–45.35% | 71.65%–71.65% | 38.34%–45.35% |
| Switch additions, eligible-page recall | 71.65%–71.65% | 61.63%–61.63% | 71.65%–71.65% | 61.63%–61.63% |
| Kind and switch together | 59.52%–60.93% | 51.56%–52.62% | 59.52%–79.03% | 51.40%–59.02% |

**Exact finite-population bounds.** Keep all owner checks fixed and vary the truth of every unchecked page. “Hand not mixed” treats unchecked agreed-handwritten pages as wholly handwritten. “Unrestricted” leaves their truth open too. These ranges are completion bounds, with no confidence level.

| Rule | Precision, hand not mixed | Recall, hand not mixed | Precision, unrestricted | Recall, unrestricted |
|---|---:|---:|---:|---:|
| ATRIUM alone | 18.29%–95.38% | 7.29%–96.76% | 18.29%–95.38% | 6.79%–96.76% |
| Kind-only handwriting pick | 14.65%–32.48% | 1.27%–34.23% | 14.65%–98.09% | 1.26%–61.11% |
| Switch additions, all-page recall | 11.89%–95.15% | 3.26%–84.48% | 11.89%–95.15% | 3.05%–84.48% |
| Switch additions, eligible-page recall | 11.89%–95.15% | 4.58%–98.99% | 11.89%–95.15% | 4.58%–98.99% |
| Kind and switch together | 12.65%–77.86% | 4.88%–90.04% | 12.65%–95.96% | 4.87%–91.76% |

With the switch off, the weights estimate 43.50 mixed hits across 46 covered calls. The owner checked 3 of those calls as nonmixed, so the exact maximum is 43. This small overshoot in the survey estimate carries through to the upper weighted precision endpoints for that row. The finite bounds give the feasible endpoints.

## Measurement card

- **Truth.** The same 170 blind owner checks and any-handwriting cut as `mixed-def-score.md` and `kind-atrium.md` §5. The owner’s threshold answers supply the truth for every rule.
- **Selection.** The same frozen 2,000-page bulk pilot and enriched owner sheet. The draw uses several classifiers’ disagreement patterns, including ATRIUM’s, plus clean controls and the census. The replay reused saved labels and features and cost $0.
- **Comparison.** Same pages with and without the switch. Replayed the bundled hand and form regressions on the saved rounded Vision features. Forms win before the hand; the routing confidence floor applies to the chosen kind. The saved ATRIUM top class supplies the downloaded flag’s positive/negative result.
- **Noise.** 19 noncensus disagreement patterns have one checked page. The finite bounds include unchecked truths within sampled patterns. The point sensitivities hold the weighted covered estimates fixed and omit their sampling uncertainty.
- **Scope.** This models direct per-image kind routing with the pre-flag downloaded and complete, a distinct runnable handwriting pick, no manual reader override, and both kind routing and the switch on. Saved features cannot observe live reader or key availability, identical reader choices, overrides, route settings, classifier/pre-flag failures, or the app’s newspaper and Finder-tag decisions. Of the 94 low-confidence printed pages, 27 have a positive flag and could become eligible if the app’s newspaper layout check promotes them. With a missing or failed flag the app falls back to allowing the switch on all 1,449 replay-eligible pages. PDFs, paid batch, gateway, Local Agent, Apple Vision and pre-OCRed input fall outside this file-list route. The scores measure routing to the handwriting reader. The text it returns, actual traffic and performance on another corpus were unmeasured.
