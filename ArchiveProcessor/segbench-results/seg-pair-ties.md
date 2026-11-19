# W46.seg-truth-audit — the segmentation tie as paired comparisons at fixed windows

Offline from cached answers; $0, no model call or upload. Each route's pages in an exact document, no checking, on the two test boxes' 325 common-support document pages (142 truth documents, Stanton and RG165, window offset 0), at its own frozen rule and level. Every pair is compared page by page on the same windows; the 95% interval resamples the truth's documents (10,000 rounds, seed 46). **A pair ties when its interval holds 0**; the settings solver then takes the cheaper route. This replaces the floor of twice the larger window-offset range (5.0 points, or 10.4 for a pair with g2; owner review of the pipeline doc, 2026-11-17).

**The rerun floor (W46.p16-seg-tie-floor, reported only: the owner kept the interval-only rule, 2026-11-18).** The interval does not cover a rerun. Byte-identical vLLM reruns of the self-hosted students moved a box's pages exact by 1.4 to 3.2 points (SEG-10; the 2B on Stanton 75.3, 76.1 and 78.6%, seg-window-modality.md; seg-kit-gate.md §Reading). The column *with the floor* calls a pair different only when its interval clears 0 and its near end also clears the larger recorded floor of its two routes (seg-qwen3.5-2b-8bit 3.2, seg-qwen3.5-2b-bf16-cluster 3.2, seg-qwen3.5-4b-cluster 3.2, qwen3.5-27b-teacher 3.2 points; a cloud route has none recorded, so 0).

| route | exact pages | pages exact | rerun floor |
|---|---:|---:|---:|
| chatgpt-gpt6.1-sol | 293 | 90.2% | none recorded |
| mix-claude-chatgpt | 293 | 90.2% | none recorded |
| claude-sonnet5.5 | 289 | 88.9% | none recorded |
| gemini3.7-flash-gateway | 289 | 88.9% | none recorded |
| gemini3.8-flash-text | 285 | 87.7% | none recorded |
| gemini3.8-flash | 284 | 87.4% | none recorded |
| glm5.3-flash | 269 | 82.8% | none recorded |
| seg-qwen3.5-4b-cluster | 269 | 82.8% | 3.2 |
| qwen3.5-27b-teacher | 264 | 81.2% | 3.2 |
| seg-qwen3.5-2b-8bit (test-box answers: the FarmShare bf16 run) | 258 | 79.4% | 3.2 |
| seg-qwen3.5-2b-bf16-cluster | 258 | 79.4% | 3.2 |

The two 2B rows are the same answers: the Mac row's test-box figure is the full-precision FarmShare run (`method_openrouter.py` `LOCAL_SEG_KEY = "fs-seg-2b"`; the Mac's 8-bit build matched it on the development boxes, 90.3% against 90.5%, seg-students.md §On the Mac). Their identical figures say nothing about rerun noise.

## Every pair, a minus b, in points of pages exact

The last two columns are for reference only: gap accuracy's paired form, McNemar's exact sign test, applied to the documents exactly right in one route and not the other (unweighted by pages). It does not decide.

| a | b | a − b | 95% paired interval | tie (in force) | with the floor | documents only a / only b right | sign test p |
|---|---|---:|---|---|---|---:|---:|
| chatgpt-gpt6.1-sol | mix-claude-chatgpt | +0.00 | [+0.00, +0.00] | tie | tie | 0 / 0 | 1.000 |
| chatgpt-gpt6.1-sol | claude-sonnet5.5 | +1.23 | [-4.23, +6.29] | tie | tie | 3 / 1 | 0.625 |
| chatgpt-gpt6.1-sol | gemini3.7-flash-gateway | +1.23 | [-4.09, +6.33] | tie | tie | 4 / 2 | 0.688 |
| chatgpt-gpt6.1-sol | gemini3.8-flash-text | +2.46 | [-2.57, +7.88] | tie | tie | 6 / 5 | 1.000 |
| chatgpt-gpt6.1-sol | gemini3.8-flash | +2.77 | [-1.69, +7.84] | tie | tie | 5 / 4 | 1.000 |
| chatgpt-gpt6.1-sol | glm5.3-flash | +7.38 | [-1.03, +16.88] | tie | tie | 7 / 2 | 0.180 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-4b-cluster | +7.38 | [-1.31, +16.56] | tie | tie | 10 / 5 | 0.302 |
| chatgpt-gpt6.1-sol | qwen3.5-27b-teacher | +8.92 | [+2.01, +16.87] | differs | tie | 9 / 3 | 0.146 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-8bit | +10.77 | [+3.91, +18.38] | differs | differs | 15 / 5 | 0.041 |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-bf16-cluster | +10.77 | [+3.91, +18.38] | differs | differs | 15 / 5 | 0.041 |
| mix-claude-chatgpt | claude-sonnet5.5 | +1.23 | [-4.23, +6.29] | tie | tie | 3 / 1 | 0.625 |
| mix-claude-chatgpt | gemini3.7-flash-gateway | +1.23 | [-4.09, +6.33] | tie | tie | 4 / 2 | 0.688 |
| mix-claude-chatgpt | gemini3.8-flash-text | +2.46 | [-2.57, +7.88] | tie | tie | 6 / 5 | 1.000 |
| mix-claude-chatgpt | gemini3.8-flash | +2.77 | [-1.69, +7.84] | tie | tie | 5 / 4 | 1.000 |
| mix-claude-chatgpt | glm5.3-flash | +7.38 | [-1.03, +16.88] | tie | tie | 7 / 2 | 0.180 |
| mix-claude-chatgpt | seg-qwen3.5-4b-cluster | +7.38 | [-1.31, +16.56] | tie | tie | 10 / 5 | 0.302 |
| mix-claude-chatgpt | qwen3.5-27b-teacher | +8.92 | [+2.01, +16.87] | differs | tie | 9 / 3 | 0.146 |
| mix-claude-chatgpt | seg-qwen3.5-2b-8bit | +10.77 | [+3.91, +18.38] | differs | differs | 15 / 5 | 0.041 |
| mix-claude-chatgpt | seg-qwen3.5-2b-bf16-cluster | +10.77 | [+3.91, +18.38] | differs | differs | 15 / 5 | 0.041 |
| claude-sonnet5.5 | gemini3.7-flash-gateway | +0.00 | [-4.78, +4.76] | tie | tie | 3 / 3 | 1.000 |
| claude-sonnet5.5 | gemini3.8-flash-text | +1.23 | [-4.79, +7.86] | tie | tie | 5 / 6 | 1.000 |
| claude-sonnet5.5 | gemini3.8-flash | +1.54 | [-3.96, +7.67] | tie | tie | 4 / 5 | 1.000 |
| claude-sonnet5.5 | glm5.3-flash | +6.15 | [+0.00, +14.37] | tie | tie | 4 / 1 | 0.375 |
| claude-sonnet5.5 | seg-qwen3.5-4b-cluster | +6.15 | [-0.64, +13.92] | tie | tie | 7 / 4 | 0.549 |
| claude-sonnet5.5 | qwen3.5-27b-teacher | +7.69 | [+0.92, +15.59] | differs | tie | 7 / 3 | 0.344 |
| claude-sonnet5.5 | seg-qwen3.5-2b-8bit | +9.54 | [+2.83, +17.08] | differs | tie | 13 / 5 | 0.096 |
| claude-sonnet5.5 | seg-qwen3.5-2b-bf16-cluster | +9.54 | [+2.83, +17.08] | differs | tie | 13 / 5 | 0.096 |
| gemini3.7-flash-gateway | gemini3.8-flash-text | +1.23 | [-4.65, +7.62] | tie | tie | 5 / 6 | 1.000 |
| gemini3.7-flash-gateway | gemini3.8-flash | +1.54 | [-3.55, +7.38] | tie | tie | 3 / 4 | 1.000 |
| gemini3.7-flash-gateway | glm5.3-flash | +6.15 | [-1.39, +14.78] | tie | tie | 6 / 3 | 0.508 |
| gemini3.7-flash-gateway | seg-qwen3.5-4b-cluster | +6.15 | [-1.22, +14.20] | tie | tie | 7 / 4 | 0.549 |
| gemini3.7-flash-gateway | qwen3.5-27b-teacher | +7.69 | [+0.33, +15.91] | differs | tie | 7 / 3 | 0.344 |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-8bit | +9.54 | [+2.30, +17.43] | differs | tie | 13 / 5 | 0.096 |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-bf16-cluster | +9.54 | [+2.30, +17.43] | differs | tie | 13 / 5 | 0.096 |
| gemini3.8-flash-text | gemini3.8-flash | +0.31 | [-3.48, +4.09] | tie | tie | 3 / 3 | 1.000 |
| gemini3.8-flash-text | glm5.3-flash | +4.92 | [-4.00, +14.43] | tie | tie | 9 / 5 | 0.424 |
| gemini3.8-flash-text | seg-qwen3.5-4b-cluster | +4.92 | [-3.54, +13.76] | tie | tie | 10 / 6 | 0.455 |
| gemini3.8-flash-text | qwen3.5-27b-teacher | +6.46 | [+0.00, +14.00] | tie | tie | 9 / 4 | 0.267 |
| gemini3.8-flash-text | seg-qwen3.5-2b-8bit | +8.31 | [+2.55, +14.97] | differs | tie | 12 / 3 | 0.035 |
| gemini3.8-flash-text | seg-qwen3.5-2b-bf16-cluster | +8.31 | [+2.55, +14.97] | differs | tie | 12 / 3 | 0.035 |
| gemini3.8-flash | glm5.3-flash | +4.62 | [-3.48, +13.62] | tie | tie | 7 / 3 | 0.344 |
| gemini3.8-flash | seg-qwen3.5-4b-cluster | +4.62 | [-3.44, +12.96] | tie | tie | 8 / 4 | 0.388 |
| gemini3.8-flash | qwen3.5-27b-teacher | +6.15 | [-0.33, +13.64] | tie | tie | 8 / 3 | 0.227 |
| gemini3.8-flash | seg-qwen3.5-2b-8bit | +8.00 | [+2.40, +14.61] | differs | tie | 11 / 2 | 0.022 |
| gemini3.8-flash | seg-qwen3.5-2b-bf16-cluster | +8.00 | [+2.40, +14.61] | differs | tie | 11 / 2 | 0.022 |
| glm5.3-flash | seg-qwen3.5-4b-cluster | +0.00 | [-9.06, +8.81] | tie | tie | 6 / 6 | 1.000 |
| glm5.3-flash | qwen3.5-27b-teacher | +1.54 | [-7.81, +10.65] | tie | tie | 6 / 5 | 1.000 |
| glm5.3-flash | seg-qwen3.5-2b-8bit | +3.38 | [-5.73, +11.97] | tie | tie | 12 / 7 | 0.359 |
| glm5.3-flash | seg-qwen3.5-2b-bf16-cluster | +3.38 | [-5.73, +11.97] | tie | tie | 12 / 7 | 0.359 |
| seg-qwen3.5-4b-cluster | qwen3.5-27b-teacher | +1.54 | [-3.51, +7.32] | tie | tie | 3 / 2 | 1.000 |
| seg-qwen3.5-4b-cluster | seg-qwen3.5-2b-8bit | +3.38 | [-4.08, +10.60] | tie | tie | 9 / 4 | 0.267 |
| seg-qwen3.5-4b-cluster | seg-qwen3.5-2b-bf16-cluster | +3.38 | [-4.08, +10.60] | tie | tie | 9 / 4 | 0.267 |
| qwen3.5-27b-teacher | seg-qwen3.5-2b-8bit | +1.85 | [-4.71, +7.69] | tie | tie | 8 / 4 | 0.388 |
| qwen3.5-27b-teacher | seg-qwen3.5-2b-bf16-cluster | +1.85 | [-4.71, +7.69] | tie | tie | 8 / 4 | 0.388 |
| seg-qwen3.5-2b-8bit | seg-qwen3.5-2b-bf16-cluster | +0.00 | [+0.00, +0.00] | tie | tie | 0 / 0 | 1.000 |

39 of 55 pairs tie under the interval alone; 51 with the floor. The sign test both ways: it separates 0 of the 39 tied pairs, and leaves 8 of the 16 differing pairs unseparated (p 0.096, 0.096, 0.096, 0.096, 0.146, 0.146, 0.344, 0.344), so the two methods agree on the ties only. It counts documents, so a long document weighs no more than a one-page letter, while pages exact, the figure the settings show, weighs each document by its pages.

With the floor, 12 of the 16 differing pairs become ties: each has the 2B, the 4B or the teacher on a side and a near end inside 3.2 points. 4 still differ: chatgpt-gpt6.1-sol over seg-qwen3.5-2b-8bit (+10.77 [+3.91, +18.38]); chatgpt-gpt6.1-sol over seg-qwen3.5-2b-bf16-cluster (+10.77 [+3.91, +18.38]); mix-claude-chatgpt over seg-qwen3.5-2b-8bit (+10.77 [+3.91, +18.38]); mix-claude-chatgpt over seg-qwen3.5-2b-bf16-cluster (+10.77 [+3.91, +18.38]).

On the boundary (an end of the interval exactly 0, counted as holding it): claude-sonnet5.5 against glm5.3-flash; gemini3.8-flash-text against qwen3.5-27b-teacher. A one-document change in either route or the truth can move such a pair either way.

Identical page by page (no document right in one and not the other): chatgpt-gpt6.1-sol and mix-claude-chatgpt; seg-qwen3.5-2b-8bit and seg-qwen3.5-2b-bf16-cluster; each pair is the same answers (the mix keeps ChatGPT's calls at its level; the 2B on the Mac row is scored from the bf16 FarmShare run, the same answers as the cluster row), not two runs.

## The differing pairs and the gaps no one re-judged (SEG-11)

Truth was re-judged only where models disagreed with it: the 92 gaps the app's Gemini route flagged (13 Nov), Stanton's magazine rulings and the 50 agreed gaps of the audit. For each pair the interval separates, the documents exactly right in one route only, and how many of them are decided at a gap the owner never looked at again (a gap in or bounding the document where the two routes' calls differ). *Neutralised* sets the winner's flags on those documents to the loser's, as if the truth were wrong at every such gap against the winner: the pair's edge if none of them counted.

| a | b | discordant documents | decided at an un-re-judged gap (for the winner) | neutralised a − b | interval / with the floor |
|---|---|---:|---:|---|---|
| chatgpt-gpt6.1-sol | qwen3.5-27b-teacher | 12 | 1 (1) | +8.31 [+1.56, +16.11] | differs / tie |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-8bit | 20 | 5 (5) | +7.69 [+1.40, +14.89] | differs / tie |
| chatgpt-gpt6.1-sol | seg-qwen3.5-2b-bf16-cluster | 20 | 5 (5) | +7.69 [+1.40, +14.89] | differs / tie |
| mix-claude-chatgpt | qwen3.5-27b-teacher | 12 | 1 (1) | +8.31 [+1.56, +16.11] | differs / tie |
| mix-claude-chatgpt | seg-qwen3.5-2b-8bit | 20 | 5 (5) | +7.69 [+1.40, +14.89] | differs / tie |
| mix-claude-chatgpt | seg-qwen3.5-2b-bf16-cluster | 20 | 5 (5) | +7.69 [+1.40, +14.89] | differs / tie |
| claude-sonnet5.5 | qwen3.5-27b-teacher | 10 | 1 (1) | +7.08 [+0.33, +14.93] | differs / tie |
| claude-sonnet5.5 | seg-qwen3.5-2b-8bit | 18 | 5 (5) | +6.46 [+0.29, +13.64] | differs / tie |
| claude-sonnet5.5 | seg-qwen3.5-2b-bf16-cluster | 18 | 5 (5) | +6.46 [+0.29, +13.64] | differs / tie |
| gemini3.7-flash-gateway | qwen3.5-27b-teacher | 10 | 1 (1) | +7.08 [+0.00, +15.26] | tie / tie |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-8bit | 18 | 5 (5) | +6.46 [-0.32, +14.03] | tie / tie |
| gemini3.7-flash-gateway | seg-qwen3.5-2b-bf16-cluster | 18 | 5 (5) | +6.46 [-0.32, +14.03] | tie / tie |
| gemini3.8-flash-text | seg-qwen3.5-2b-8bit | 15 | 5 (5) | +5.23 [+0.00, +11.31] | tie / tie |
| gemini3.8-flash-text | seg-qwen3.5-2b-bf16-cluster | 15 | 5 (5) | +5.23 [+0.00, +11.31] | tie / tie |
| gemini3.8-flash | seg-qwen3.5-2b-8bit | 13 | 5 (5) | +4.92 [+0.00, +11.01] | tie / tie |
| gemini3.8-flash | seg-qwen3.5-2b-bf16-cluster | 13 | 5 (5) | +4.92 [+0.00, +11.01] | tie / tie |

Neutralised, 7 of the 16 pairs would tie under the interval alone: gemini3.7-flash-gateway over qwen3.5-27b-teacher; gemini3.7-flash-gateway over seg-qwen3.5-2b-8bit; gemini3.7-flash-gateway over seg-qwen3.5-2b-bf16-cluster; gemini3.8-flash-text over seg-qwen3.5-2b-8bit; gemini3.8-flash-text over seg-qwen3.5-2b-bf16-cluster; gemini3.8-flash over seg-qwen3.5-2b-8bit; gemini3.8-flash over seg-qwen3.5-2b-bf16-cluster. These are the verdicts an owner look at those gaps could move; no truth is changed here.

## The picks the floor would move (not changed; the owner kept the interval-only rule, 2026-11-18)

The settings solver's profile tests run on a scratch table that reads the floor column. Profiles that keep their pick: D3 (the Claude plan only: Claude), D4, D5 (a Claude plan and a Gemini key: Claude), B1-B4, C (the 2B already), and any profile with an OpenAI key, where ChatGPT or the mix still differs from the 2B.

| profile | pick now | with the floor |
|---|---|---|
| D1, a Gemini key on a 16 GB Mac | gemini3.8-flash-text (87.7%, $1.68) | seg-qwen3.5-2b-8bit (79.4%, $0) |
| D1, Gemini and OpenRouter keys | glm5.3-flash (82.8%, $1.16) | seg-qwen3.5-2b-8bit |
| D1, only g2 and the 2B usable | gemini3.8-flash (87.4%, $3.61) | seg-qwen3.5-2b-8bit |
| E, a cluster with a Gemini key | seg-qwen3.5-4b-cluster (82.8%) | seg-qwen3.5-2b-bf16-cluster (79.4%) |
| an Anthropic key only on a Mac (no test case; by the rule) | claude-sonnet5.5 (88.9%) | seg-qwen3.5-2b-8bit |

## Measurement card

- **Truth.** Owner-ruled Stanton and RG165 (truth photo labels), with W46.seg-truth-owner-fixes' eight corrections; the two unknown RG165 gaps leave 325 of 330 document pages. Truth has been re-judged only where models disagreed; the agreed-gap audit (seg-truth-audit.md) asks the owner about agreed gaps.
- **Selection.** The whole frozen test boxes; no gap or document chosen by any route's answers.
- **Comparison.** Same pages, same windows (offset 0), each route's own frozen rule and level, as in the settings table; each route's count is checked against its table figure before any pair is formed.
- **Noise.** The paired interval covers document sampling on these two boxes. It does not cover window placement (Gemini 3.7's offsets move pages exact 2.5 points on g1, 5.2 on g2: seg-g2-offsets.md), which pairing on the same windows takes out of the comparison, nor a rerun: a fixed window does not give a fixed answer. Byte-identical vLLM reruns of the self-hosted students moved a box 1.4-3.2 points (SEG-10), and the 'with the floor' column carries the 3.2 for every pair with a student. No cloud route has an identical-window rerun scored, so its floor is unmeasured and counted 0; a g2 rerun of the 363 pages (about $1.3 at list) would measure one. Every differing pair has a student on a side.
- **Scope.** Pages exact with no checking only. Not a forecast for other material; per-box intervals are not formed (two boxes); checking cost and after-checking figures are compared as before.

