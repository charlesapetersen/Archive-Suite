# W46.seg-truth-audit — the segmentation tie as paired comparisons at fixed windows

Offline from cached answers; $0, no model call or upload. Each route's pages in an exact document, no checking, on the two test boxes' 325 common-support document pages (142 truth documents, Stanton and RG165, window offset 0), at its own frozen rule and level. Every pair is compared page by page on the same windows; the 95% interval resamples the truth's documents (10,000 rounds, seed 46). **A pair ties when its interval holds 0**; the settings solver then takes the cheaper route. This replaces the floor of twice the larger window-offset range (5.0 points, or 10.4 for a pair with g2; owner review of the pipeline doc, 2026-11-17).

| route | exact pages | pages exact |
|---|---:|---:|
| chatgpt-gpt6.1-sol | 293 | 90.2% |
| mix-claude-chatgpt | 293 | 90.2% |
| claude-sonnet5.5 | 289 | 88.9% |
| gemini3.7-flash-gateway | 289 | 88.9% |
| gemini3.8-flash-text | 285 | 87.7% |
| gemini3.8-flash | 284 | 87.4% |
| glm5.3-flash | 269 | 82.8% |
| seg-qwen3.5-4b-cluster | 269 | 82.8% |
| qwen3.5-27b-teacher | 264 | 81.2% |
| seg-qwen3.5-2b-8bit | 258 | 79.4% |
| seg-qwen3.5-2b-bf16-cluster | 258 | 79.4% |

## Every pair, a minus b, in points of pages exact

The last two columns are for reference only: gap accuracy's paired form, McNemar's exact sign test, applied to the documents exactly right in one route and not the other (unweighted by pages). It does not decide.

| a | b | a − b | 95% paired interval | tie | documents only a / only b right | sign test p |
|---|---|---:|---|---|---:|---:|
| chatgpt-gpt6.1-sol | mix-claude-chatgpt | +0.00 | [+0.00, +0.00] | tie | 0 / 0 | 1.000 |
| chatgpt-gpt6.1-sol | claude-sonnet5.5 | +1.23 | [-4.23, +6.29] | tie | 3 / 1 | 0.625 |
| chatgpt-gpt6.1-sol | gemini3.7-flash-gateway | +1.23 | [-4.09, +6.33] | tie | 4 / 2 | 0.688 |
| chatgpt-gpt6.1-sol | gemini3.8-flash-text | +2.46 | [-2.57, +7.88] | tie | 6 / 5 | 1.000 |
| chatgpt-gpt6.1-sol | gemini3.8-flash | +2.77 | [-1.69, +7.84] | tie | 5 / 4 | 1.000 |
| chatgpt-gpt6.1-sol | glm5.3-flash | +7.38 | [-1.03, +16.88] | tie | 7 / 2 | 0.180 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-4b-cluster | +7.38 | [-1.31, +16.56] | tie | 10 / 5 | 0.302 |
| chatgpt-gpt6.1-sol | qwen3.5-27b-teacher | +8.92 | [+2.01, +16.87] | differs | 9 / 3 | 0.146 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-8bit | +10.77 | [+3.91, +18.38] | differs | 15 / 5 | 0.041 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-bf16-cluster | +10.77 | [+3.91, +18.38] | differs | 15 / 5 | 0.041 |
| mix-claude-chatgpt | claude-sonnet5.5 | +1.23 | [-4.23, +6.29] | tie | 3 / 1 | 0.625 |
| mix-claude-chatgpt | gemini3.7-flash-gateway | +1.23 | [-4.09, +6.33] | tie | 4 / 2 | 0.688 |
| mix-claude-chatgpt | gemini3.8-flash-text | +2.46 | [-2.57, +7.88] | tie | 6 / 5 | 1.000 |
| mix-claude-chatgpt | gemini3.8-flash | +2.77 | [-1.69, +7.84] | tie | 5 / 4 | 1.000 |
| mix-claude-chatgpt | glm5.3-flash | +7.38 | [-1.03, +16.88] | tie | 7 / 2 | 0.180 |
| mix-claude-chatgpt | seg-qwen3.5-4b-cluster | +7.38 | [-1.31, +16.56] | tie | 10 / 5 | 0.302 |
| mix-claude-chatgpt | qwen3.5-27b-teacher | +8.92 | [+2.01, +16.87] | differs | 9 / 3 | 0.146 |
| mix-claude-chatgpt | seg-qwen3.5-2b-8bit | +10.77 | [+3.91, +18.38] | differs | 15 / 5 | 0.041 |
| mix-claude-chatgpt | seg-qwen3.5-2b-bf16-cluster | +10.77 | [+3.91, +18.38] | differs | 15 / 5 | 0.041 |
| claude-sonnet5.5 | gemini3.7-flash-gateway | +0.00 | [-4.78, +4.76] | tie | 3 / 3 | 1.000 |
| claude-sonnet5.5 | gemini3.8-flash-text | +1.23 | [-4.79, +7.86] | tie | 5 / 6 | 1.000 |
| claude-sonnet5.5 | gemini3.8-flash | +1.54 | [-3.96, +7.67] | tie | 4 / 5 | 1.000 |
| claude-sonnet5.5 | glm5.3-flash | +6.15 | [+0.00, +14.37] | tie | 4 / 1 | 0.375 |
| claude-sonnet5.5 | seg-qwen3.5-4b-cluster | +6.15 | [-0.64, +13.92] | tie | 7 / 4 | 0.549 |
| claude-sonnet5.5 | qwen3.5-27b-teacher | +7.69 | [+0.92, +15.59] | differs | 7 / 3 | 0.344 |
| claude-sonnet5.5 | seg-qwen3.5-2b-8bit | +9.54 | [+2.83, +17.08] | differs | 13 / 5 | 0.096 |
| claude-sonnet5.5 | seg-qwen3.5-2b-bf16-cluster | +9.54 | [+2.83, +17.08] | differs | 13 / 5 | 0.096 |
| gemini3.7-flash-gateway | gemini3.8-flash-text | +1.23 | [-4.65, +7.62] | tie | 5 / 6 | 1.000 |
| gemini3.7-flash-gateway | gemini3.8-flash | +1.54 | [-3.55, +7.38] | tie | 3 / 4 | 1.000 |
| gemini3.7-flash-gateway | glm5.3-flash | +6.15 | [-1.39, +14.78] | tie | 6 / 3 | 0.508 |
| gemini3.7-flash-gateway | seg-qwen3.5-4b-cluster | +6.15 | [-1.22, +14.20] | tie | 7 / 4 | 0.549 |
| gemini3.7-flash-gateway | qwen3.5-27b-teacher | +7.69 | [+0.33, +15.91] | differs | 7 / 3 | 0.344 |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-8bit | +9.54 | [+2.30, +17.43] | differs | 13 / 5 | 0.096 |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-bf16-cluster | +9.54 | [+2.30, +17.43] | differs | 13 / 5 | 0.096 |
| gemini3.8-flash-text | gemini3.8-flash | +0.31 | [-3.48, +4.09] | tie | 3 / 3 | 1.000 |
| gemini3.8-flash-text | glm5.3-flash | +4.92 | [-4.00, +14.43] | tie | 9 / 5 | 0.424 |
| gemini3.8-flash-text | seg-qwen3.5-4b-cluster | +4.92 | [-3.54, +13.76] | tie | 10 / 6 | 0.455 |
| gemini3.8-flash-text | qwen3.5-27b-teacher | +6.46 | [+0.00, +14.00] | tie | 9 / 4 | 0.267 |
| gemini3.8-flash-text | seg-qwen3.5-2b-8bit | +8.31 | [+2.55, +14.97] | differs | 12 / 3 | 0.035 |
| gemini3.8-flash-text | seg-qwen3.5-2b-bf16-cluster | +8.31 | [+2.55, +14.97] | differs | 12 / 3 | 0.035 |
| gemini3.8-flash | glm5.3-flash | +4.62 | [-3.48, +13.62] | tie | 7 / 3 | 0.344 |
| gemini3.8-flash | seg-qwen3.5-4b-cluster | +4.62 | [-3.44, +12.96] | tie | 8 / 4 | 0.388 |
| gemini3.8-flash | qwen3.5-27b-teacher | +6.15 | [-0.33, +13.64] | tie | 8 / 3 | 0.227 |
| gemini3.8-flash | seg-qwen3.5-2b-8bit | +8.00 | [+2.40, +14.61] | differs | 11 / 2 | 0.022 |
| gemini3.8-flash | seg-qwen3.5-2b-bf16-cluster | +8.00 | [+2.40, +14.61] | differs | 11 / 2 | 0.022 |
| glm5.3-flash | seg-qwen3.5-4b-cluster | +0.00 | [-9.06, +8.81] | tie | 6 / 6 | 1.000 |
| glm5.3-flash | qwen3.5-27b-teacher | +1.54 | [-7.81, +10.65] | tie | 6 / 5 | 1.000 |
| glm5.3-flash | seg-qwen3.5-2b-8bit | +3.38 | [-5.73, +11.97] | tie | 12 / 7 | 0.359 |
| glm5.3-flash | seg-qwen3.5-2b-bf16-cluster | +3.38 | [-5.73, +11.97] | tie | 12 / 7 | 0.359 |
| seg-qwen3.5-4b-cluster | qwen3.5-27b-teacher | +1.54 | [-3.51, +7.32] | tie | 3 / 2 | 1.000 |
| seg-qwen3.5-4b-cluster | seg-qwen3.5-2b-8bit | +3.38 | [-4.08, +10.60] | tie | 9 / 4 | 0.267 |
| seg-qwen3.5-4b-cluster | seg-qwen3.5-2b-bf16-cluster | +3.38 | [-4.08, +10.60] | tie | 9 / 4 | 0.267 |
| qwen3.5-27b-teacher | seg-qwen3.5-2b-8bit | +1.85 | [-4.71, +7.69] | tie | 8 / 4 | 0.388 |
| qwen3.5-27b-teacher | seg-qwen3.5-2b-bf16-cluster | +1.85 | [-4.71, +7.69] | tie | 8 / 4 | 0.388 |
| seg-qwen3.5-2b-8bit | seg-qwen3.5-2b-bf16-cluster | +0.00 | [+0.00, +0.00] | tie | 0 / 0 | 1.000 |

39 of 55 pairs tie. The sign test would separate 0 of the tied pairs (p under 0.05): it counts documents, so a long document weighs no more than a one-page letter, while pages exact, the figure the settings show, weighs each document by its pages.

## Measurement card

- **Truth.** Owner-ruled Stanton and RG165 (truth photo labels), with W46.seg-truth-owner-fixes' eight corrections; the two unknown RG165 gaps leave 325 of 330 document pages. Truth has been re-judged only where models disagreed; the agreed-gap audit (seg-truth-audit.md) asks the owner about agreed gaps.
- **Selection.** The whole frozen test boxes; no gap or document chosen by any route's answers.
- **Comparison.** Same pages, same windows (offset 0), each route's own frozen rule and level, as in the settings table; each route's count is checked against its table figure before any pair is formed.
- **Noise.** The paired interval covers document sampling on these two boxes. It does not cover window placement (Gemini 3.7's offsets move pages exact 2.5 points on g1, 5.2 on g2: seg-g2-offsets.md) or a rerun; at temperature 0 a fixed window gives a fixed answer, so pairing on the same windows removes placement from the comparison rather than adding it to the floor.
- **Scope.** Pages exact with no checking only. Not a forecast for other material; per-box intervals are not formed (two boxes); checking cost and after-checking figures are compared as before.

