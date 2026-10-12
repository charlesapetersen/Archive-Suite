# W36.seg-opt-openai — ChatGPT on the development set

Run 2026-10-12 on Dean, Deaver and Herrnstein (551 pages, 494 gaps between two document pages); the test collections are not touched. Truth photo labels. Held out per box, as in `options-dev.md`. Method: `scripts/segbench/options.py`, the `*-openai` commands.

Voters: C = window-claude (Claude Sonnet 5.5, prompt w1); G = window-gemini-3.8-flash-low (Gemini 3.8 Flash, thinking low, prompt g1); O = window-openai (OpenAI gpt-6.1-sol through Codex, reasoning low, prompt c1).

## ChatGPT alone, held out per box

| approach | boxes at 98% after review | no review | flagged per 100 pages | after review | worst box | unflagged errors (per 500 pages) | levels (Dean / Deaver / Herrnstein) |
|---|---:|---:|---:|---:|---:|---:|---|
| openai (O) | 3 of 3 | 91.3% | 79.1 | 100.0% | 100.0% | 0 (0.0) | <= 0.990 / <= 0.990 / <= 0.990 |

## The mix re-ranked with ChatGPT

Same ranking as `options-dev.md`: boxes reaching 98% after review, then flagged per 100 pages, then unflagged errors. The first is the mix offered.

| voters | rule | boxes at 98% | flagged per 100 pages | unflagged errors | no review | after review |
|---|---|---:|---:|---:|---:|---:|
| CO | min | 3 of 3 | 5.8 | 2 | 91.1% | 99.0% |
| CG | min | 3 of 3 | 6.0 | 2 | 90.7% | 99.0% |
| CGO | min | 3 of 3 | 6.0 | 2 | 90.7% | 99.0% |
| GO | mean | 2 of 3 | 3.1 | 3 | 90.7% | 98.5% |
| GO | min | 2 of 3 | 3.8 | 3 | 90.7% | 98.3% |
| CGO | mean | 2 of 3 | 4.5 | 3 | 90.7% | 98.5% |
| CO | mean | 2 of 3 | 4.9 | 3 | 91.1% | 98.5% |
| CG | mean | 2 of 3 | 5.4 | 3 | 90.7% | 98.6% |

## By box (held out)

| approach | box | level | flagged | unflagged errors | no review | after review |
|---|---|---|---:|---:|---:|---:|
| openai | Dean | <= 0.990 | 167 | 0 | 86.2% | 100.0% |
| openai | Deaver | <= 0.990 | 132 | 0 | 97.9% | 100.0% |
| openai | Herrnstein | <= 0.990 | 137 | 0 | 91.7% | 100.0% |

## Frozen for the test set

- openai: level <= 0.990 (fitted on all three development boxes).
- mix: CO, min, level <= 0.850; **changed** from the scored CG, min, <= 0.850, so the mix row is scored again on the test boxes.

