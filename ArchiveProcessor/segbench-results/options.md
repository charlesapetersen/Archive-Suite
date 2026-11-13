# Segmentation approaches — the figures the Processor will show

W36.seg-opt-measure, run 2026-10-11. Data for the app: `options.json` beside this file. Method: `scripts/segbench/options.py`; the development-set detail is `options-dev.md`.

**Measured on the locked boxes, Stanton and RG 165 (363 pages, 315 gaps between two document pages), scored once**, with each approach's flag level and the mix rule frozen on the development boxes (Dean, Deaver, Herrnstein) before the test boxes' new calls were made (`options-frozen.json`, committed first). Truth photo labels. Claude's test-box answers were collected for W36.seg-ensemble at the same level (0.85), and its row here equals that record; Gemini 3.8 Flash's test-box windows are new. ChatGPT was measured afterwards (2026-10-12, W36.seg-opt-openai) the same way, its level frozen first (`options-frozen-openai.json`). Rescored 2026-11-13 from the same cached answers on a changed truth (W46.seg-truth-owner-fixes: the owner corrected 8 Stanton and RG 165 gaps and left RG 165 79|80 and 99|100 unsure, judging W46.seg-check-time's differing answers with three pages either side; earlier, on 2026-10-31 (W46.seg-truth-rescore), he split Stanton 101-105's newsletter issue at 101|102 and 102|103 under the article-within-issue rule); nothing was refit or re-chosen. On 2026-11-11 the Gemini voter moved to prompt g2 (W46.seg-magazine-rule-app): its level (<= 0.965) and every Gemini only figure are Gemini 3.7 Flash through the Stanford gateway, prompt g2 (W46.seg-magazine-rule-app; the gateway does not serve 3.8, and the owner declined a 3.8 run on the personal key, 2026-11-10), fitted and scored as above; the figures it replaced (3.8 on g1) are kept in options.json as the row's `replaces`.

Denominators: 'per 100 pages', 'per 500 pages' and 'per 1,000 pages' count every page photographed, box and folder photos included; 'pages in an exact document' counts document pages only.

## The five figures, per approach (test boxes)

| approach | pages in an exact document, no checking | boundaries to check per 100 pages | pages right after checking | unflagged errors per 500 pages (count) | API cost per 1,000 pages, list / batch |
|---|---:|---:|---:|---:|---:|
| Full manual | — | 86.8 | 100.0% | 0.0 (0) | none |
| Claude only | 89.1% | 10.2 | 98.5% | 1.4 (1) | $16.93 / $8.47 |
| Gemini only | 87.6% | 25.3 | 100.0% | 0.0 (0) | $3.61 / $1.81 |
| ChatGPT only | 90.3% | 79.1 | 100.0% | 0.0 (0) | $14.51 / $7.25 |
| Claude and ChatGPT together | 90.3% | 10.2 | 98.5% | 1.4 (1) | $31.44 / $15.72 |
| GLM-5.3 Flash only (budget) | 83.0% | 33.1 | 97.0% | 4.1 (3) | $1.16 / none |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | 79.7% | 78.8 | 98.8% | 1.4 (1) | $0.000 / none |
| Gemini only, text alone (budget) | 87.9% | 29.2 | 98.5% | 1.4 (1) | $1.68 / $0.842 |

Gemini only is labelled: the app's voter is Gemini 3.8 Flash sending g2, and this row's level and figures are Gemini 3.7 Flash's g2 answers through the Stanford gateway, the level fitted on them (segbench-results/seg-magazine-rule-app.md). Gemini 3.8 on g1 at <= 0.965 scored 90.0% no checking, 24.2 checks per 100 pages, 97.0% after checking and 3 unflagged errors. Its token and price row below is 3.8's, measured on g1. The row is one run at window offset 0; over offsets 0, 1 and 2 (segbench-results/seg-g2-offsets.md) the same route scores 84.8%–90.0% no checking, 25.3–29.2 checks per 100 pages, 98.5%–100.0% after checking, 0.0–1.4 unflagged errors per 500 pages.

## Held out on the development boxes (each box at the level fitted on the other two)

| approach | rule, level for the test | no checking | to check per 100 pages | after checking | unflagged per 500 pages |
|---|---|---:|---:|---:|---:|
| Claude only | min, <= 0.850 | 90.7% | 5.8 | 99.0% | 1.8 |
| Gemini only | min, <= 0.965 | 91.9% | 10.2 | 98.6% | 2.7 |
| ChatGPT only | min, <= 0.990 | 91.3% | 79.1 | 100.0% | 0.0 |
| Claude and ChatGPT together | min, <= 0.850 | 91.1% | 5.8 | 99.0% | 1.8 |
| GLM-5.3 Flash only (budget) | min, <= 0.925 | 90.2% | 17.1 | 97.3% | 2.7 |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | min, <= 0.995 | 90.5% | 73.3 | 100.0% | 0.0 |
| Gemini only, text alone (budget) | min, <= 0.950 | 89.4% | 11.8 | 99.0% | 1.8 |

## By test box

| approach | box | pages | no checking | flagged | per 100 pages | after checking | unflagged errors |
|---|---|---:|---:|---:|---:|---:|---:|
| Claude only | Stanton | 250 | 85.2% | 32 | 12.8 | 97.9% | 1 |
| Claude only | RG165 | 113 | 100.0% | 5 | 4.4 | 100.0% | 0 |
| Gemini only | Stanton | 250 | 86.8% | 81 | 32.4 | 100.0% | 0 |
| Gemini only | RG165 | 113 | 89.7% | 11 | 9.7 | 100.0% | 0 |
| ChatGPT only | Stanton | 250 | 89.3% | 221 | 88.4 | 100.0% | 0 |
| ChatGPT only | RG165 | 113 | 93.1% | 66 | 58.4 | 100.0% | 0 |
| Claude and ChatGPT together | Stanton | 250 | 89.3% | 32 | 12.8 | 97.9% | 1 |
| Claude and ChatGPT together | RG165 | 113 | 93.1% | 5 | 4.4 | 100.0% | 0 |
| GLM-5.3 Flash only (budget) | Stanton | 250 | 78.2% | 93 | 37.2 | 95.9% | 3 |
| GLM-5.3 Flash only (budget) | RG165 | 113 | 96.6% | 27 | 23.9 | 100.0% | 0 |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | Stanton | 250 | 74.9% | 213 | 85.2 | 98.4% | 1 |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | RG165 | 113 | 93.1% | 73 | 64.6 | 100.0% | 0 |
| Gemini only, text alone (budget) | Stanton | 250 | 86.0% | 85 | 34.0 | 97.9% | 1 |
| Gemini only, text alone (budget) | RG165 | 113 | 93.1% | 21 | 18.6 | 100.0% | 0 |

## Tokens and cost per 1,000 pages

Measured over every box collected (all five), not tuned on anything. Gemini: the API's own usage figures. Claude: each window rebuilt as one Messages API request and counted with count_tokens (free); the bench itself ran through `claude -p`, whose notional list-price figure is shown for the subscription route; its output count assumes no extended thinking on the API route. A mix pays for both models.

| model | boxes | calls | input tokens | output tokens | list $ | batch $ | prices $/M in, out (read) |
|---|---|---:|---:|---:|---:|---:|---|
| claude-sonnet-5-5 | Dean, Deaver, Herrnstein, RG165, Stanton | 310 | 7,724k | 148k | $16.93 | $8.47 | 2.0, 10.0 (2026-10-11) |
| gemini-3.8-flash/low | Dean, Deaver, Herrnstein, RG165, Stanton | 310 | 3,942k | 174k | $3.61 | $1.81 | 0.75, 3.75 (2026-10-05) |
| gpt-6.1-sol/low | Dean, Herrnstein, RG165, Stanton | 259 | 12,213k | 91k | $14.51 | $7.25 | 2.0, 10.0 (2026-10-11) |
| z-ai/glm-5.3-flash/minimal | Dean, Deaver, Herrnstein, RG165, Stanton | 313 | 7,227k | 149k | $1.16 | — | 0.15, 0.5 (2026-10-13) |
| seg-qwen3.5-2b-8bit/off | Dean, Deaver, Herrnstein, RG165, Stanton | 310 | 3,315k | 130k | $0.000 | — | runs on this Mac; no provider is paid |

Gemini 3.8 Flash is at its introductory price to 31 Dec 2026; at the later $1.50 / $7.50 the Gemini figure becomes $7.22 list, $3.61 batch.

Claude through `claude -p` (the subscription route, about 8 agent turns a window as the images are read with a tool): the CLI's notional list price is $50.29 per 1,000 pages. A subscription is not charged that; it is the size of the usage the route draws, which W36.seg-opt-usage turns into a share of a plan's windows.

ChatGPT through `codex exec` (the ChatGPT subscription; no money): Codex reported 12,213k input tokens per 1,000 pages, of which 4,096k cached, and its harness alone is 16,000 input tokens a call; the cost column is computed on the 6,796k left once that is taken off, which is what one API request of each window would carry. Output includes reasoning.

## Reading

- Manual asks about every gap between two document pages (87 per 100 pages on these boxes) and costs nothing; it is the floor the others are measured against.
- On the test boxes the fewest checks were Claude only's (10.2 per 100 pages, 1 unflagged errors), and the fewest unflagged errors Gemini only's (0, at 25.3 checks per 100 pages; ChatGPT only ties it at 79.1). The trade-off is the level: a higher one flags more and leaves less.
- Every count here is small (Claude only 1 on the test boxes, 2 held out on the development boxes, Gemini only 0 on the test boxes, 3 held out on the development boxes, ChatGPT only 0 on the test boxes, 0 held out on the development boxes, Claude and ChatGPT together 1 on the test boxes, 2 held out on the development boxes, GLM-5.3 Flash only (budget) 3 on the test boxes, 3 held out on the development boxes, Corpus-trained Qwen3.5 2B on this Mac (no key) 1 on the test boxes, 0 held out on the development boxes, Gemini only, text alone (budget) 1 on the test boxes, 2 held out on the development boxes), so a difference of one or two errors is within noise, and a zero on 363 pages is not a promise of zero. The figures shown to a user should be the rounded test figures, labelled as measured on two locked boxes (363 pages) of one archive.
- The models make the same mistakes more often than different ones (on Dean, Claude and Gemini took the same decision on every gap), which is why combining them adds little over Claude alone.

## Measurement card

- **Truth.** The owner's ruled test boxes, Stanton (with the owner's 2026-10-31 segmentation-sheet rulings, W46.seg-truth-rescore) and RG 165, with the truth's photo labels, and the owner's 2026-11-13 corrections (W46.seg-truth-owner-fixes: 8 gaps changed after he judged W46.seg-check-time's differing answers with three pages either side; seg-truth-owner-fixes.json). RG 165 79|80 and 99|100 he could not tell and are left out of every count (score.py, UNSURE GAPS); only those 12 gaps were looked at again. Levels and the mix rule were frozen on the owner's development boxes (Dean, Deaver, Herrnstein). Gemini only is Gemini 3.7 Flash's g2 answers through the gateway, at the level fitted on its own development answers (0.965, the level 3.8 had on g1; W46.seg-magazine-rule-app), so it has no unflagged error. Gemini 3.8 on g1, the row it replaced, has 3: Stanton 101|102 and 102|103, the newsletter gaps the owner re-ruled on 2026-10-31 under the article-within-issue rule, and 26|27. Every cloud route on its old prompt merges the pair (g1's rule 10 stated the full-magazine rule; Claude and ChatGPT merge them flagged, GLM-5.3 Flash accepted), and the 2B trained on the owner's corpus splits them (seg-boxes-score.json, newsletter_gaps). Prompt g2, g1 with rule 10 on the article-within-issue rule, splits both (seg-magazine-rule.md). ChatGPT's c1 still carries g1's rule 10 until the plan-route hold lifts (W46.gateway-models-ok). GLM-5.3 Flash's 3 are that pair and 144|145; Claude's 1 (Stanton 144|145) and the Mac 2B's 1 (a false split at Stanton 108|109) do not include it (`seg_truth_owner_fixes.py errors`, from the cached answers).
- **Selection.** Whole boxes chosen before these routes existed; the approaches are the ones the app offers, not picked by their test score. Nothing was fitted, chosen or re-chosen on the test boxes.
- **Comparison.** Every approach on the same 363 pages and gaps, with its own flag level frozen first (`options-frozen.json`) and its own route's request and settings as cached; costs at list token prices.
- **Noise.** Single runs with no intervals. The error counts are a few gaps each, so a difference of one or two is within noise; the rerun floor (1.4-3.2 points of pages exact a box, SEG-10) applies to the no-review column. Gemini only's five figures are one g2 run on 3.7 at window offset 0; over three offsets it scores 84.8%-90.0% no checking (seg-g2-offsets.md), and 3.7 on g1 at the same level 87.0%-89.4% (seg-boxes-score.md).
- **Scope.** The figures the Processor shows for one archive's two locked boxes (363 pages). Not other material (the three locked owner boxes are scored in seg-boxes-score.md; Lincoln and CREST are not scored here), and not a forecast for a user's own corpus.

