# Gemini 3.7 Flash (Stanford gateway) on the 895 public pages (W46.ocr-gemini37-895-paid)

The gateway default had read only the owner's 96; this is its reading of the 895 frozen public pages, with W46.gemini37-vs-38's settings (the panel prompt, temperature 0, low reasoning, 8,192 output tokens) and the reference routes' 2,400 px JPEGs (the 440 reused byte for byte, the 455 made by the same code). NES is `ocr_panel_score.score`; **strict** counts a failed page as 0, **answered** is over the pages it read. The bench's other scorers (cMER, NewsBench bowF1, added and rewritten words) for this route are in `ocr-scorers.md`, beside every route on the 895; its NES there, through `ocr_scorers.py`, can differ from this table's by a few tenths. Script `scripts/segbench/ocr_gemini37_public.py`.

| set | pages | read | NES strict | NES answered |
|---|---:|---:|---:|---:|
| all 895 | 895 | 879 | 77.2 | 78.6 |
| the 440 | 440 | 434 | 73.9 | 74.9 |
| the 455 | 455 | 445 | 80.4 | 82.2 |

Against Gemini 3.8 Flash's cached reading of the 440 (OpenRouter, W43.corpus-build; 3.8 read 419/440): on the 417 both read, 3.7 74.6 against 3.8 74.4, paired 3.7 less 3.8 +0.12 points (95% bootstrap -0.66 to +0.93; permutation p 0.762).

| stratum | pages | read | NES strict | NES answered | both read (440) | 3.7 | 3.8 |
|---|---:|---:|---:|---:|---:|---:|---:|
| L1 | 80 | 80 | 91.1 | 91.1 | 0 | - | - |
| L2 | 80 | 80 | 80.3 | 80.3 | 0 | - | - |
| L3 | 80 | 80 | 95.8 | 95.8 | 0 | - | - |
| L4 | 80 | 80 | 83.2 | 83.2 | 0 | - | - |
| L5 | 80 | 80 | 64.6 | 64.6 | 79 | 64.2 | 64.3 |
| L6 | 80 | 76 | 82.6 | 86.9 | 67 | 85.9 | 86.5 |
| L7 | 80 | 80 | 58.5 | 58.5 | 78 | 58.8 | 59.4 |
| L8 | 80 | 80 | 92.4 | 92.4 | 78 | 92.7 | 92.7 |
| L9 | 15 | 15 | 96.8 | 96.8 | 0 | - | - |
| N1 | 40 | 39 | 78.2 | 80.3 | 36 | 81.0 | 80.7 |
| N2 | 40 | 30 | 24.0 | 32.0 | 0 | - | - |
| N3 | 40 | 39 | 89.6 | 91.9 | 39 | 91.9 | 91.1 |
| N4 | 40 | 40 | 48.6 | 48.6 | 40 | 48.6 | 46.1 |
| N5 | 40 | 40 | 84.0 | 84.0 | 0 | - | - |
| N6 | 40 | 40 | 68.9 | 68.9 | 0 | - | - |

Calls 895 (HTTP errors: none); finish reasons {'stop': 878, 'content_filter': 16, 'length': 1}. Tokens 1,289,701 in, 865,185 out; median 8.195 s a page. Spend about $4.21, an estimate at Gemini 3.8 Flash's list $0.75/$3.75 per M tokens (the gateway returns no cost), Stanford PTA.

## Measurement card

- **Truth:** each public dataset's own ground-truth transcription, frozen with the 895 (W43.corpus-build; `bench-corpus/manifest.jsonl` checksums). Not drafted by any scored route; the owner did not check them.
- **Selection:** the frozen 895, stratified at freeze time by source and script; no page chosen by a tested route or by ABBYY text.
- **Comparison:** the same images (the 440 byte for byte), prompt, output cap, temperature 0 and low reasoning as Gemini 3.8 Flash's reference reading of the 440, and as 3.7 on the 96. Both OCR sets: the 96 is `gemini37-vs-38.md` with the same settings, and `ocr-scorers.md` carries the route on both.
- **Noise:** n = 895 (paired with 3.8 on 417); the paired interval above. Gemini 3.7's rerun range on the 96 is 0.24 points (`ocr-rerun-noise.md`, W46.ocr-rerun-noise); a gap under twice it, or an interval crossing 0, is a tie, so 3.7 and 3.8 tie on the 440. No rerun on the 895. The 16 unread pages are all Gemini content-filter refusals (finish `content_filter`, empty text), model failures, not transport.
- **Scope:** one reading, one prompt, one image size; it says how the gateway default reads the public strata, not which route the app should use for them, and nothing about the owner's material beyond the 96.
