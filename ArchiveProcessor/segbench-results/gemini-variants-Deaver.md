# Gemini variants on Deaver (development box)

Same windows, prompt and assembly as W36.seg-second; only the model and thinkingLevel differ. Own photo labels. One box, so a difference of a few pages is within noise.

| model | thinking | pages in exact doc | false splits | false merges | calls | thinking tokens/call | cost |
|---|---|---|---|---|---|---|---|
| gemini-3.1-flash-lite | minimal | 72.3% | 16 | 1 | 51 | 0 | $0.20 |
| gemini-3.5-flash-lite | minimal | 74.5% | 14 | 2 | 51 | 0 | $0.26 |
| gemini-3.8-flash | low | 97.9% | 0 | 1 | 51 | 0 | $0.57 |
| gemini-3.8-flash | high | 97.9% | 0 | 1 | 51 | 3405 | $1.22 |

Prices: list, standard tier, found 2026-10-05; 3.8 Flash at its introductory price to 31 Dec 2026. window-claude on this box: see window-claude-dev.tsv.
