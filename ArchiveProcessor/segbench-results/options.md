# Segmentation approaches — the figures the Processor will show

W36.seg-opt-measure, run 2026-10-11. Data for the app: `options.json` beside this file. Method: `scripts/segbench/options.py`; the development-set detail is `options-dev.md`.

**Measured on the locked boxes, Stanton and RG 165 (363 pages, 315 gaps between two document pages), scored once**, with each approach's flag level and the mix rule frozen on the development boxes (Dean, Deaver, Herrnstein) before the test boxes' new calls were made (`options-frozen.json`, committed first). Truth photo labels. Claude's test-box answers were collected for W36.seg-ensemble at the same level (0.85), and its row here equals that record; Gemini 3.8 Flash's test-box windows are new. ChatGPT was measured afterwards (2026-10-12, W36.seg-opt-openai) the same way, its level frozen first (`options-frozen-openai.json`).

Denominators: 'per 100 pages', 'per 500 pages' and 'per 1,000 pages' count every page photographed, box and folder photos included; 'pages in an exact document' counts document pages only.

## The five figures, per approach (test boxes)

| approach | pages in an exact document, no checking | boundaries to check per 100 pages | pages right after checking | unflagged errors per 500 pages (count) | API cost per 1,000 pages, list / batch |
|---|---:|---:|---:|---:|---:|
| Full manual | — | 86.8 | 100.0% | 0.0 (0) | none |
| Claude only | 87.0% | 10.2 | 97.3% | 4.1 (3) | $16.93 / $8.47 |
| Gemini only | 88.8% | 24.2 | 100.0% | 0.0 (0) | $3.61 / $1.81 |
| ChatGPT only | 92.4% | 79.1 | 100.0% | 0.0 (0) | $14.51 / $7.25 |
| Claude and ChatGPT together | 92.4% | 10.2 | 97.3% | 4.1 (3) | $31.44 / $15.72 |

## Held out on the development boxes (each box at the level fitted on the other two)

| approach | rule, level for the test | no checking | to check per 100 pages | after checking | unflagged per 500 pages |
|---|---|---:|---:|---:|---:|
| Claude only | min, <= 0.850 | 90.7% | 5.8 | 99.0% | 1.8 |
| Gemini only | min, <= 0.965 | 90.7% | 10.3 | 98.6% | 2.7 |
| ChatGPT only | min, <= 0.990 | 91.3% | 79.1 | 100.0% | 0.0 |
| Claude and ChatGPT together | min, <= 0.850 | 91.1% | 5.8 | 99.0% | 1.8 |

## By test box

| approach | box | pages | no checking | flagged | per 100 pages | after checking | unflagged errors |
|---|---|---:|---:|---:|---:|---:|---:|
| Claude only | Stanton | 250 | 86.8% | 32 | 12.8 | 97.1% | 2 |
| Claude only | RG165 | 113 | 87.4% | 5 | 4.4 | 97.7% | 1 |
| Gemini only | Stanton | 250 | 89.3% | 77 | 30.8 | 100.0% | 0 |
| Gemini only | RG165 | 113 | 87.4% | 11 | 9.7 | 100.0% | 0 |
| ChatGPT only | Stanton | 250 | 91.8% | 221 | 88.4 | 100.0% | 0 |
| ChatGPT only | RG165 | 113 | 94.3% | 66 | 58.4 | 100.0% | 0 |
| Claude and ChatGPT together | Stanton | 250 | 91.8% | 32 | 12.8 | 97.1% | 2 |
| Claude and ChatGPT together | RG165 | 113 | 94.3% | 5 | 4.4 | 97.7% | 1 |

## Tokens and cost per 1,000 pages

Measured over every box collected (all five), not tuned on anything. Gemini: the API's own usage figures. Claude: each window rebuilt as one Messages API request and counted with count_tokens (free); the bench itself ran through `claude -p`, whose notional list-price figure is shown for the subscription route; its output count assumes no extended thinking on the API route. A mix pays for both models.

| model | boxes | calls | input tokens | output tokens | list $ | batch $ | prices $/M in, out (read) |
|---|---|---:|---:|---:|---:|---:|---|
| claude-sonnet-5-5 | Dean, Deaver, Herrnstein, RG165, Stanton | 310 | 7,724k | 148k | $16.93 | $8.47 | 2.0, 10.0 (2026-10-11) |
| gemini-3.8-flash/low | Dean, Deaver, Herrnstein, RG165, Stanton | 310 | 3,942k | 174k | $3.61 | $1.81 | 0.75, 3.75 (2026-10-05) |
| gpt-6.1-sol/low | Dean, Herrnstein, RG165, Stanton | 259 | 12,213k | 91k | $14.51 | $7.25 | 2.0, 10.0 (2026-10-11) |

Gemini 3.8 Flash is at its introductory price to 31 Dec 2026; at the later $1.50 / $7.50 the Gemini figure becomes $7.22 list, $3.61 batch.

Claude through `claude -p` (the subscription route, about 8 agent turns a window as the images are read with a tool): the CLI's notional list price is $50.29 per 1,000 pages. A subscription is not charged that; it is the size of the usage the route draws, which W36.seg-opt-usage turns into a share of a plan's windows.

ChatGPT through `codex exec` (the ChatGPT subscription; no money): Codex reported 12,213k input tokens per 1,000 pages, of which 4,096k cached, and its harness alone is 16,000 input tokens a call; the cost column is computed on the 6,796k left once that is taken off, which is what one API request of each window would carry. Output includes reasoning.

## Reading

- Manual asks about every gap between two document pages (87 per 100 pages on these boxes) and costs nothing; it is the floor the others are measured against.
- On the test boxes the fewest checks were Claude only's (10.2 per 100 pages, 3 unflagged errors), and the fewest unflagged errors Gemini only's (0, at 24.2 checks per 100 pages). The trade-off is the level: a higher one flags more and leaves less.
- Every count here is small (Claude only 3 on the test boxes, 2 held out on the development boxes, Gemini only 0 on the test boxes, 3 held out on the development boxes, ChatGPT only 0 on the test boxes, 0 held out on the development boxes, Claude and ChatGPT together 3 on the test boxes, 2 held out on the development boxes), so a difference of one or two errors is within noise, and a zero on 363 pages is not a promise of zero. The figures shown to a user should be the rounded test figures, labelled as measured on two locked boxes (363 pages) of one archive.
- The models make the same mistakes more often than different ones (on Dean, Claude and Gemini took the same decision on every gap), which is why combining them adds little over Claude alone.

