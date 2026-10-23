# Gemini 3.7 Flash (Stanford gateway) against Gemini 3.8 Flash (OpenRouter) on the owner's 96 (W46.fix-ocr-scorers-paid)

The same 96 scored pages (99 settled jobs less the three agreement pages), the same images (2,400 px, the cloud panel's), the same prompt, temperature 0 and low reasoning. 3.8 is the cached W41.ocr-panel-cloud reading; 3.7 was read on 2026-10-23 through the gateway (`scripts/segbench/gateway_gemini.py`). NES is the panel's score (`ocr_panel_score.score`), a failed page counting 0. Later gateway arms that run 3.7 should read their figures against 3.8's with the difference below in mind.

| | Gemini 3.8 Flash | Gemini 3.7 Flash |
|---|---:|---:|
| pages read | 94/96 | 96/96 |
| NES, all 96 (failure = 0) | 94.5 | 96.7 |
| NES, the 94 both read | 96.5 | 96.9 |
| kind right | 87 | 87 |
| cost of the 96 | $0.309 (OpenRouter, billed) | $0.373 (estimate, at 3.8's list $0.75/$3.75 per M) |

Paired difference, 3.7 less 3.8, on the 94 pages both read: +0.42 NES points (95% bootstrap -0.26 to +1.22; permutation p 0.248).

| kind | pages | 3.8 NES | 3.7 NES |
|---|---:|---:|---:|
| handwritten | 16 | 96.0 | 95.1 |
| mixed | 2 | 77.1 | 83.8 |
| printed | 26 | 93.9 | 95.4 |
| typewritten | 50 | 98.7 | 98.8 |

3.7 used 137,639 input and 71,985 output tokens (25,809 of them reasoning) on the 96; median 9.43 s a page.

## Original pages (96, excluding the agreement-only letters)

| route | completed / attempted / 96 | NES % | chrF2 % | words missed % | words added % | kind right % | cost / page |
|---|---:|---:|---:|---:|---:|---:|---:|
| gemini3.7-flash-gw · Stanford AI API gateway | 96/96/96 | 96.74 | 97.47 | 0.56 | 0.98 | 91 | $0.00389 (estimate) |
