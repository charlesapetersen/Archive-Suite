# Page difficulty, failures and cascades (W41.bench-difficulty)

Built by `ArchiveOCRBench/build.py` from `segbench-results/ocr-pages.csv` and `ocr-pages-agree.csv` (`scripts/segbench/ocr_pages_export.py` writes them from the panels' private caches); edit `difficulty.py`, not this file. No new calls were made: every figure is the panel's measured reading of its 96 accuracy pages, by 29 routes.

The owner's framing (2026-10-15): what matters most is that the text that comes back is accurate. A page that fails goes on to another model; it is not inaccurate text. So accuracy on answered pages and failures are ranked apart, with page difficulty in the picture so that a route that fails only hard pages is not flattered, and cascades are simulated to see whether cheap readers can take the easy pages.

## 1. Two rankings: accuracy on the pages answered, and failures

**NES at average difficulty** fits NES = route ability + page easiness to every answered reading, so a route that skipped hard pages is not credited for it: it is the route's expected NES on a page of average difficulty. **Page mix** is how much easier than average the pages it answered were, in NES points (a positive figure is what answered-only accuracy flatters). The bench's strict NES, which scores a failure 0, is beside them. A poor reading is an answered page under 90 NES.

| route | $ / 1,000 | answered | NES on answered | NES at average difficulty | page mix | poor readings | failed | failed pages that are hard | strict NES (bench) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Gemini 3.1 Pro | $21.92 | 94 | 96.86 | 96.84 | +0.14 | 10 | 2 | 1 | 94.84 |
| Gemini 3.8 Flash | $3.22 | 94 | 96.48 | 96.46 | +0.14 | 6 | 2 | 1 | 94.47 |
| Claude Sonnet 5.5 | $11.50 | 96 | 96.47 | 96.59 | +0.00 | 8 | 0 | – | 96.47 |
| Qwen3.5 27B | $1.80 | 82 | 95.76 | 95.07 | +0.81 | 10 | 14 | 6 | 81.80 |
| Gemini 3.5 Flash | $6.23 | 94 | 95.47 | 95.45 | +0.14 | 7 | 2 | 1 | 93.48 |
| Qwen3.6 27B | $1.94 | 95 | 95.27 | 95.33 | +0.06 | 13 | 1 | 1 | 94.28 |
| Qwen3.6 27B fp8 (FarmShare) | $1.95 | 96 | 95.25 | 95.37 | +0.00 | 14 | 0 | – | 95.25 |
| Gemini 3.5 Flash Lite | $1.57 | 94 | 95.11 | 95.09 | +0.14 | 12 | 2 | 1 | 93.13 |
| Qwen3.8 Flash | $0.60 | 93 | 94.84 | 95.12 | -0.16 | 12 | 3 | 0 | 91.88 |
| Gemini 3.1 Flash Lite | $1.17 | 93 | 94.56 | 94.54 | +0.14 | 12 | 3 | 2 | 91.61 |
| GPT-5.4 Mini | $5.55 | 95 | 94.53 | 94.72 | -0.07 | 17 | 1 | 0 | 93.55 |
| Qwen3.5 397B | $2.02 | 96 | 93.98 | 94.10 | +0.00 | 16 | 0 | – | 93.98 |
| Qwen3-VL 235B | $1.22 | 96 | 93.95 | 94.07 | +0.00 | 16 | 0 | – | 93.95 |
| Qwen3-VL 8B | $1.49 | 94 | 93.76 | 93.59 | +0.29 | 20 | 2 | 2 | 91.81 |
| Qwen3-VL 8B 4-bit (Mac) | free | 92 | 93.56 | 93.40 | +0.28 | 21 | 4 | 3 | 89.66 |
| Gemma 4 31B | $0.38 | 93 | 93.47 | 92.86 | +0.72 | 21 | 3 | 3 | 90.55 |
| Qwen3.5 9B | $0.25 | 92 | 93.32 | 93.61 | -0.18 | 20 | 4 | 1 | 89.43 |
| Mistral Large 4 | $2.69 | 96 | 93.15 | 93.27 | +0.00 | 19 | 0 | – | 93.15 |
| GPT-5.6 Luna | $1.41 | 95 | 93.10 | 93.29 | -0.07 | 19 | 1 | 0 | 92.13 |
| Qwen3.6 35B-A3B | $0.60 | 96 | 93.02 | 93.14 | +0.00 | 17 | 0 | – | 93.02 |
| Mistral OCR 4.1 | $4.00 | 96 | 92.91 | 93.03 | +0.00 | 17 | 0 | – | 92.91 |
| Qwen3.5-9B 4-bit (Mac) | free | 95 | 92.88 | 93.04 | -0.05 | 19 | 1 | 0 | 91.91 |
| Qwen3.5 35B-A3B | $0.83 | 94 | 92.76 | 92.81 | +0.07 | 19 | 2 | 1 | 90.83 |
| Gemma 4 26B-A4B | $0.41 | 86 | 92.35 | 91.29 | +1.18 | 23 | 10 | 5 | 82.73 |
| Qwen3-VL 30B-A3B | $0.98 | 94 | 91.73 | 91.80 | +0.05 | 25 | 2 | 2 | 89.82 |
| Mistral Small 24B | $0.32 | 94 | 91.24 | 91.03 | +0.34 | 24 | 2 | 2 | 89.34 |
| Mistral Medium 3.5 | $7.29 | 96 | 90.65 | 90.77 | +0.00 | 29 | 0 | – | 90.65 |
| LightOnOCR-3-4B 8-bit (Mac) | free | 96 | 89.13 | 89.25 | +0.00 | 27 | 0 | – | 89.13 |
| Apple Vision | free | 96 | 81.34 | 81.46 | +0.00 | 41 | 0 | – | 81.34 |

Answered-only accuracy flatters most the routes that fail often: Gemma 4 26B-A4B (+1.18, 10 failed), Qwen3.5 27B (+0.81, 14 failed), Gemma 4 31B (+0.72, 3 failed). For the routes that answer everything the adjustment is a constant shift. Failures are a separate count; a cascade turns them into money, not into lost text (part 4).

## 2. Page difficulty

A page's difficulty is one minus the mean NES of the other routes' answered readings of it (leave one out: the route being judged never sets its own pages' difficulty). Thirds of the pages by that measure:

| tier | mean NES of all routes | typewritten | printed | handwritten | mixed |
|---|---:|---:|---:|---:|---:|
| easy | 99.50 | 24 | 8 | 0 | 0 |
| middle | 97.34 | 16 | 11 | 5 | 0 |
| hard | 82.74 | 10 | 9 | 11 | 2 |

Handwritten pages: 0 easy, 5 middle, 11 hard; but 10 of the 32 hard pages are typewritten and 9 printed. The ten hardest pages average 68.64 NES across routes (typewritten, mixed, printed, printed, handwritten, printed, handwritten, printed, typewritten, typewritten). A page's difficulty and the number of routes that fail it are only loosely related (correlation 0.29): most failures are a call that errored, a reply that ran to the token limit or broke the reply format, or a refusal, not a reading that came out badly.

### Accuracy on answered pages by difficulty and by kind

Each route's own thirds, from its leave-one-out difficulty; failed pages in brackets.

| route | easy | middle | hard | typewritten | printed | handwritten |
|---|---:|---:|---:|---:|---:|---:|
| Gemini 3.1 Pro | 99.78 | 99.31 (1) | 91.40 (1) | 98.75 | 96.07 (2) | 94.06 |
| Gemini 3.8 Flash | 99.89 | 99.41 (1) | 90.02 (1) | 98.75 | 93.92 (2) | 95.97 |
| Claude Sonnet 5.5 | 99.84 | 99.11 | 90.45 | 98.58 | 96.31 | 92.43 |
| Qwen3.5 27B | 99.87 (4) | 98.62 (4) | 88.27 (6) | 97.98 (6) | 95.70 (4) | 92.18 (4) |
| Gemini 3.5 Flash | 99.85 | 98.57 (1) | 87.85 (1) | 97.33 | 94.96 (2) | 92.93 |
| Qwen3.6 27B | 99.83 | 98.12 | 87.63 (1) | 97.50 (1) | 94.82 | 92.15 |
| Qwen3.6 27B fp8 (FarmShare) | 99.83 | 98.46 | 87.47 | 97.22 | 94.93 | 92.80 |
| Gemini 3.5 Flash Lite | 99.54 | 98.00 (1) | 87.64 (1) | 97.56 | 94.69 (2) | 91.98 |
| Qwen3.8 Flash | 99.66 (1) | 98.24 (2) | 86.98 | 97.31 (2) | 94.65 (1) | 91.03 |
| Gemini 3.1 Flash Lite | 99.66 | 98.71 (1) | 84.84 (2) | 96.38 | 93.53 (2) | 92.42 (1) |
| GPT-5.4 Mini | 99.72 (1) | 98.71 | 85.33 | 97.46 (1) | 93.32 | 89.48 |
| Qwen3.5 397B | 99.81 | 97.84 | 84.29 | 96.18 | 93.72 | 90.57 |
| Qwen3-VL 235B | 99.80 | 98.33 | 83.71 | 96.09 | 93.25 | 91.38 |
| Qwen3-VL 8B | 99.76 | 96.73 | 84.20 (2) | 95.56 | 94.61 (1) | 90.49 (1) |
| Qwen3-VL 8B 4-bit (Mac) | 99.55 | 97.01 (1) | 83.25 (3) | 95.41 (2) | 95.09 (1) | 89.16 |
| Gemma 4 31B | 98.76 | 95.79 | 85.07 (3) | 96.67 (1) | 89.70 (2) | 90.84 |
| Qwen3.5 9B | 99.34 (1) | 96.15 (2) | 84.56 (1) | 95.35 (3) | 92.97 (1) | 90.92 |
| Mistral Large 4 | 99.70 | 97.01 | 82.73 | 95.46 | 92.46 | 92.03 |
| GPT-5.6 Luna | 99.63 (1) | 97.84 | 82.03 | 96.92 (1) | 92.61 | 85.44 |
| Qwen3.6 35B-A3B | 99.81 | 97.59 | 81.67 | 95.69 | 92.34 | 88.82 |
| Mistral OCR 4.1 | 99.42 | 97.81 | 81.51 | 95.70 | 91.49 | 89.01 |
| Qwen3.5-9B 4-bit (Mac) | 99.56 | 98.15 (1) | 81.09 | 95.24 (1) | 92.78 | 87.92 |
| Qwen3.5 35B-A3B | 99.79 | 98.11 (1) | 80.15 (1) | 96.10 (2) | 91.09 | 88.31 |
| Gemma 4 26B-A4B | 98.51 (1) | 96.79 (4) | 80.67 (5) | 95.42 (3) | 91.11 (6) | 86.60 |
| Qwen3-VL 30B-A3B | 99.58 | 97.20 | 77.53 (2) | 95.56 | 91.43 (1) | 82.75 (1) |
| Mistral Small 24B | 99.28 | 96.92 | 76.62 (2) | 95.44 (1) | 89.33 | 85.16 (1) |
| Mistral Medium 3.5 | 98.80 | 96.06 | 77.10 | 94.67 | 87.98 | 85.04 |
| LightOnOCR-3-4B 8-bit (Mac) | 96.21 | 95.04 | 76.14 | 90.81 | 87.98 | 89.67 |
| Apple Vision | 95.27 | 86.62 | 62.13 | 91.92 | 76.43 | 57.87 |

On its easy third every route but Apple Vision (95.27) reads 96.21 or better; on the hard third the routes run from 62.13 to 91.40, which is where the ranking comes from.

## 3. Do failures fall on hard pages?

For each route that failed any page: where its failed pages sit in its own difficulty order (0 = the easiest page, 100 = the hardest; 50 is what failures at random would give) and how many are in the hard third.

| route | failed | mean difficulty percentile | in the hard third | by kind |
|---|---:|---:|---:|---|
| Qwen3.5 27B | 14 | 59 | 6 | handwritten 4, printed 4, typewritten 6 |
| Gemma 4 26B-A4B | 10 | 70 | 5 | mixed 1, printed 6, typewritten 3 |
| Qwen3-VL 8B 4-bit (Mac) | 4 | 74 | 3 | mixed 1, printed 1, typewritten 2 |
| Qwen3.5 9B | 4 | 48 | 1 | printed 1, typewritten 3 |
| Qwen3.8 Flash | 3 | 38 | 0 | printed 1, typewritten 2 |
| Gemini 3.1 Flash Lite | 3 | 72 | 2 | handwritten 1, printed 2 |
| Gemma 4 31B | 3 | 91 | 3 | printed 2, typewritten 1 |
| Gemini 3.1 Pro | 2 | 71 | 1 | printed 2 |
| Gemini 3.8 Flash | 2 | 71 | 1 | printed 2 |
| Gemini 3.5 Flash | 2 | 71 | 1 | printed 2 |
| Gemini 3.5 Flash Lite | 2 | 71 | 1 | printed 2 |
| Qwen3-VL 8B | 2 | 91 | 2 | handwritten 1, printed 1 |
| Qwen3.5 35B-A3B | 2 | 65 | 1 | typewritten 2 |
| Qwen3-VL 30B-A3B | 2 | 75 | 2 | handwritten 1, printed 1 |
| Mistral Small 24B | 2 | 93 | 2 | handwritten 1, typewritten 1 |
| Qwen3.6 27B | 1 | 82 | 1 | typewritten 1 |
| GPT-5.4 Mini | 1 | 20 | 0 | typewritten 1 |
| GPT-5.6 Luna | 1 | 20 | 0 | typewritten 1 |
| Qwen3.5-9B 4-bit (Mac) | 1 | 49 | 0 | typewritten 1 |

Failures lean toward harder pages but are not confined to them: for 14 of the 19 routes that failed, the failed pages sit above the median difficulty, while GPT-5.4 Mini and GPT-5.6 Luna failed only easier pages. Most routes failed one to four pages, so these percentiles are anecdotes, not rates.

## 4. Cascades

Simulated from the measured readings: each page goes to the first stage, and on to the next when the trigger fires; the text kept is the last stage's. A cascade's cost is each stage's measured cost for the pages it read (a route's bench price shared out by its per-page cost, so escalated long pages cost what long pages cost), at standard prices. First stages and the second reader in a disagreement check are the cheap routes ($1.00 per 1,000 pages or less, or free); later stages are any route a user of the app can run (FarmShare is left out). Triggers: the stage failed; it failed or labelled the page handwritten or mixed; it failed or its text and a second cheap reader's differ (NES between the two under 0.80, 0.85, 0.90, 0.95). 18,538 candidates in all.

The Mac routes are free in money but not in time: about 40 s a page on the 18 GB M3 Pro (`ocr-mac-local.md`), and a cascade with two Mac readers spends that twice.

### The best candidate at each budget, and what choosing it from half the pages is worth

Choosing the best of thousands of candidates on 96 pages flatters the choice. So each family is also chosen 200 times on a random half of the pages and scored on the other half: the last column is what that way of choosing delivers on pages it did not see.

| budget, $ / 1,000 | family | best on all pages | NES | $ | escalated | chosen on half → other half |
|---:|---|---|---:|---:|---:|---:|
| 0 | one route | Qwen3.5-9B 4-bit (Mac) | 91.91 | free | – | 91.95 → 91.88 |
| 0 | escalate on failure | Qwen3-VL 8B 4-bit (Mac) → Qwen3.5-9B 4-bit (Mac) | 93.42 | free | 4 | 93.54 → 92.65 |
| 0 | on failure or a handwritten/mixed label | Qwen3-VL 8B 4-bit (Mac) → LightOnOCR-3-4B 8-bit (Mac) (and its handwritten or mixed pages) | 93.23 | free | 22 | 93.50 → 92.27 |
| 0 | on failure, Vision's handwriting pages sent straight on | Qwen3-VL 8B 4-bit (Mac) → Qwen3.5-9B 4-bit (Mac) (Vision's handwriting pages straight to Qwen3.5-9B 4-bit (Mac)) | 93.41 | free | 18 | 93.63 → 92.88 |
| 0 | on failure or two cheap readers disagreeing | Qwen3-VL 8B 4-bit (Mac), checked against Apple Vision at 0.90 → Qwen3.5-9B 4-bit (Mac) | 93.26 | free | 44 | 93.60 → 91.63 |
| 0.5 | one route | Qwen3.5-9B 4-bit (Mac) | 91.91 | free | – | 92.25 → 90.84 |
| 0.5 | escalate on failure | Qwen3.5 9B → Gemini 3.8 Flash | 93.58 | $0.41 | 4 | 94.20 → 92.12 |
| 0.5 | on failure or a handwritten/mixed label | Qwen3-VL 8B 4-bit (Mac) → Qwen3.6 27B (and its handwritten or mixed pages) | 94.14 | $0.39 | 22 | 94.48 → 92.57 |
| 0.5 | on failure, Vision's handwriting pages sent straight on | Qwen3-VL 8B 4-bit (Mac) → Qwen3.6 27B (Vision's handwriting pages straight to Qwen3.6 27B) | 93.91 | $0.32 | 18 | 94.43 → 92.57 |
| 0.5 | on failure or two cheap readers disagreeing | LightOnOCR-3-4B 8-bit (Mac), checked against Qwen3.5 9B at 0.90 → Qwen3.8 Flash | 94.97 | $0.44 | 32 | 95.58 → 92.60 |
| 1 | one route | Qwen3.6 35B-A3B | 93.02 | $0.60 | – | 93.55 → 91.25 |
| 1 | escalate on failure | Qwen3.8 Flash → Gemini 3.1 Flash Lite | 95.00 | $0.64 | 3 | 95.06 → 93.98 |
| 1 | on failure or a handwritten/mixed label | Qwen3.8 Flash → Gemini 3.5 Flash Lite (and its handwritten or mixed pages) | 95.05 | $0.86 | 23 | 95.43 → 93.46 |
| 1 | on failure, Vision's handwriting pages sent straight on | Qwen3.8 Flash → Qwen3.6 27B (Vision's handwriting pages straight to Qwen3.6 27B) | 95.22 | $0.83 | 18 | 95.42 → 93.87 |
| 1 | on failure or two cheap readers disagreeing | Qwen3.6 35B-A3B, checked against Qwen3.5 9B at 0.90 → Qwen3.8 Flash | 95.42 | $0.95 | 16 | 96.20 → 93.41 |
| 2 | one route | Qwen3.6 27B | 94.28 | $1.94 | – | 94.84 → 92.55 |
| 2 | escalate on failure | Qwen3.6 27B → Gemini 3.8 Flash | 95.29 | $1.97 | 1 | 95.66 → 93.64 |
| 2 | on failure or a handwritten/mixed label | Qwen3.8 Flash → Gemini 3.8 Flash (and its handwritten or mixed pages) | 95.29 | $1.44 | 23 | 95.77 → 93.83 |
| 2 | on failure, Vision's handwriting pages sent straight on | Qwen3.8 Flash → Gemini 3.8 Flash (Vision's handwriting pages straight to Gemini 3.8 Flash) | 95.83 | $1.25 | 18 | 95.88 → 95.06 |
| 2 | on failure or two cheap readers disagreeing | Qwen3.8 Flash, checked against Qwen3.5 9B at 0.85 → Gemini 3.8 Flash | 96.14 | $1.39 | 16 | 96.65 → 94.21 |
| 5 | one route | Gemini 3.8 Flash | 94.47 | $3.22 | – | 95.34 → 92.81 |
| 5 | escalate on failure | Gemini 3.8 Flash → Qwen3.5 35B-A3B | 96.39 | $3.24 | 2 | 96.58 → 94.87 |
| 5 | on failure or a handwritten/mixed label | Qwen3.8 Flash → Claude Sonnet 5.5 (and its handwritten or mixed pages) | 95.49 | $3.36 | 23 | 95.92 → 94.02 |
| 5 | on failure, Vision's handwriting pages sent straight on | Qwen3.8 Flash → Gemini 3.8 Flash (Vision's handwriting pages straight to Gemini 3.8 Flash) | 95.83 | $1.25 | 18 | 95.88 → 94.98 |
| 5 | on failure or two cheap readers disagreeing | Qwen3.6 35B-A3B, checked against Gemma 4 26B-A4B at 0.90 → Claude Sonnet 5.5 | 96.41 | $4.48 | 29 | 96.84 → 94.47 |
| 25 | one route | Claude Sonnet 5.5 | 96.47 | $11.50 | – | 96.56 → 95.56 |
| 25 | escalate on failure | Gemini 3.1 Pro → Qwen3.5 35B-A3B | 96.77 | $21.94 | 2 | 96.99 → 95.30 |
| 25 | on failure or a handwritten/mixed label | Qwen3.8 Flash → Gemini 3.1 Pro (and its handwritten or mixed pages) | 95.72 | $5.33 | 23 | 95.99 → 94.28 |
| 25 | on failure, Vision's handwriting pages sent straight on | Qwen3.8 Flash → Gemini 3.8 Flash (Vision's handwriting pages straight to Gemini 3.8 Flash) | 95.83 | $1.25 | 18 | 95.88 → 94.98 |
| 25 | on failure or two cheap readers disagreeing | Qwen3.5 35B-A3B, checked against Gemma 4 31B at 0.95 → Claude Sonnet 5.5 | 96.52 | $5.64 | 37 | 96.90 → 94.66 |

What holds up on pages the choice did not see:

- **Escalating on failure is the robust gain.** At every budget up to $5 per 1,000 pages, a cascade that sends failures on, chosen on half the pages, beat one route chosen the same way by 0.8 to 2.7 NES points on the other half. Much of that is simply the failed pages coming back: a failure scores 0, and a cascade turns it into a second reading.
- **The disagreement check** finds answered-but-wrong pages (part 5) and tops most budgets on all pages, but it is the most flattered family. On unseen pages it is +0.48 at $0.5, -0.57 at $1, +0.57 at $2, -0.40 at $5 against escalation on failure alone.
- **A hard-kind label** (the reader's own handwritten or mixed label) is +0.45 at $0.5, -0.52 at $1, +0.19 at $2, -0.85 at $5 against failure alone on unseen pages: no reliable gain. The labels are weak (part 5).
- **At the top, one strong reader still wins**: at $25 the single-route choice gives 95.56 on unseen pages, the best cascade family 95.30.

### The frontier on all pages

| cascade | NES | $ / 1,000 | escalated | failed |
|---|---:|---:|---:|---:|
| Qwen3-VL 8B 4-bit (Mac) → Qwen3.5-9B 4-bit (Mac) | 93.42 | free | 4 | 0 |
| Qwen3.5-9B 4-bit (Mac), checked against Qwen3-VL 8B 4-bit (Mac) at 0.80 → Qwen3.5 9B | 93.72 | $0.02 | 10 | 0 |
| Qwen3.5-9B 4-bit (Mac), checked against Qwen3-VL 8B 4-bit (Mac) at 0.85 → Qwen3.5 9B | 94.21 | $0.02 | 13 | 0 |
| Qwen3.5-9B 4-bit (Mac), checked against Apple Vision at 0.80 → Qwen3.5 9B | 94.34 | $0.07 | 33 | 0 |
| Qwen3-VL 8B 4-bit (Mac), checked against LightOnOCR-3-4B 8-bit (Mac) at 0.85 → Qwen3.8 Flash | 94.68 | $0.11 | 19 | 0 |
| LightOnOCR-3-4B 8-bit (Mac), checked against Qwen3-VL 8B 4-bit (Mac) at 0.90 → Qwen3.8 Flash | 94.90 | $0.16 | 29 | 0 |
| LightOnOCR-3-4B 8-bit (Mac), checked against Qwen3.5 9B at 0.90 → Qwen3.8 Flash | 94.97 | $0.44 | 32 | 0 |
| Qwen3.8 Flash → Qwen3.5 9B (Vision's handwriting pages straight to Qwen3.5 9B) | 95.00 | $0.55 | 18 | 0 |
| Qwen3.8 Flash → Qwen3.6 35B-A3B (Vision's handwriting pages straight to Qwen3.6 35B-A3B) | 95.11 | $0.59 | 18 | 0 |
| Qwen3.6 35B-A3B, checked against Qwen3-VL 8B 4-bit (Mac) at 0.80 → Qwen3.8 Flash | 95.42 | $0.67 | 11 | 0 |
| Qwen3.6 35B-A3B, checked against Qwen3.5 9B at 0.90 → Qwen3.8 Flash | 95.42 | $0.95 | 16 | 0 |
| Qwen3.5-9B 4-bit (Mac), checked against Qwen3.8 Flash at 0.90 → Gemini 3.8 Flash | 95.52 | $1.19 | 21 | 0 |
| Qwen3.6 35B-A3B, checked against Qwen3.5 9B at 0.80 → Gemini 3.8 Flash | 95.63 | $1.22 | 12 | 0 |
| Qwen3.8 Flash → Gemini 3.8 Flash (Vision's handwriting pages straight to Gemini 3.8 Flash) | 95.83 | $1.25 | 18 | 0 |
| Qwen3.6 35B-A3B, checked against Qwen3.5 9B at 0.90 → Gemini 3.8 Flash | 95.99 | $1.33 | 16 | 0 |
| Qwen3.8 Flash, checked against Qwen3.5 9B at 0.85 → Gemini 3.8 Flash | 96.14 | $1.39 | 16 | 0 |
| Gemini 3.8 Flash → Qwen3.5-9B 4-bit (Mac) | 96.38 | $3.22 | 2 | 0 |
| Gemini 3.8 Flash → Qwen3.5 35B-A3B | 96.39 | $3.24 | 2 | 0 |
| Qwen3.6 35B-A3B, checked against Gemma 4 26B-A4B at 0.90 → Claude Sonnet 5.5 | 96.41 | $4.48 | 29 | 0 |
| Qwen3.5 35B-A3B, checked against Gemma 4 31B at 0.95 → Claude Sonnet 5.5 | 96.52 | $5.64 | 37 | 0 |
| Gemini 3.1 Pro → Qwen3.5-9B 4-bit (Mac) | 96.76 | $21.92 | 2 | 0 |
| Gemini 3.1 Pro → Qwen3.5 35B-A3B | 96.77 | $21.94 | 2 | 0 |

## 5. What flags an answered page that is wrong

A cascade sees a failure; it does not see a poor reading. For each cheap first reader, how well its signals pick out its answered pages under 90 NES: AUC (0.5 is chance, 1 is perfect) and how many of the poor readings fall in the fifth of its pages the signal ranks most suspect. **Length** compares its word count with Apple Vision's on the same page (free, on the device). **Disagreement** is one minus the NES between its text and a second cheap reader's; the partner shown is the best of the cheap readers, itself chosen on these pages. **Kind** is its own label, and **Vision** is whether Vision OCR's page sorter calls the page handwriting (part 6), the same for every reader. No route reports a confidence: the panel's prompt asks for none and the APIs used return no token probabilities, so that signal was not available.

| reader | answered | poor readings | kind label: AUC, caught | Vision: handwriting: AUC, caught | length: AUC, caught | disagreement: partner, AUC, caught |
|---|---:|---:|---|---|---|---|
| Qwen3.8 Flash | 93 | 12 | 0.66, 6 | 0.60, 4 | 0.87, 9 | Qwen3.6 35B-A3B, 0.91, 10 |
| Qwen3.6 35B-A3B | 96 | 17 | 0.63, 7 | 0.51, 3 | 0.85, 11 | LightOnOCR-3-4B 8-bit (Mac), 0.89, 12 |
| Qwen3.5 35B-A3B | 94 | 19 | 0.64, 8 | 0.60, 6 | 0.89, 14 | LightOnOCR-3-4B 8-bit (Mac), 0.91, 13 |
| Gemma 4 31B | 93 | 21 | 0.57, 6 | 0.55, 6 | 0.89, 14 | Qwen3.6 35B-A3B, 0.95, 14 |
| Qwen3-VL 30B-A3B | 94 | 25 | 0.68, 12 | 0.64, 9 | 0.87, 16 | Apple Vision, 0.95, 15 |
| Qwen3.5 9B | 92 | 20 | 0.66, 9 | 0.56, 6 | 0.79, 13 | Qwen3.6 35B-A3B, 0.92, 15 |
| Mistral Small 24B | 94 | 24 | 0.67, 11 | 0.60, 9 | 0.89, 15 | Qwen3.6 35B-A3B, 0.94, 17 |
| Gemma 4 26B-A4B | 86 | 23 | 0.70, 11 | 0.62, 8 | 0.85, 14 | Qwen3.6 35B-A3B, 0.97, 17 |
| Apple Vision | 96 | 41 | – | 0.68, 15 | – | Qwen3.6 35B-A3B, 0.97, 19 |
| Qwen3-VL 8B 4-bit (Mac) | 92 | 21 | 0.65, 9 | 0.62, 8 | 0.82, 14 | Qwen3.6 35B-A3B, 0.96, 17 |
| LightOnOCR-3-4B 8-bit (Mac) | 96 | 27 | – | 0.55, 7 | 0.78, 14 | Qwen3.6 35B-A3B, 0.95, 16 |
| Qwen3.5-9B 4-bit (Mac) | 95 | 19 | 0.70, 10 | 0.60, 6 | 0.85, 14 | Qwen3.6 35B-A3B, 0.92, 15 |

Disagreement between two cheap readers is the strong signal (AUC 0.89 to 0.97), and length against Apple Vision's reading is a free second (0.78 to 0.89). The model's own kind label is weak (0.57 to 0.70): the models often label a page differently from the truth (the panel's `kind_correct`), and poor readings are spread over printed and typewritten pages as well as handwritten ones.

## Failures on the real corpus

FarmShare's bulk pilot (Qwen3.6 27B, 2,000 random corpus pages, no truth): 13 failed (13 unparsed (length)). By the kind the model gave the page:

| kind (model's label) | pages | failed | failure rate |
|---|---:|---:|---:|
| typewritten | 1,202 | 5 | 0.4% |
| printed | 487 | 5 | 1.0% |
| mixed | 167 | 2 | 1.2% |
| handwritten | 144 | 1 | 0.7% |

No kind fails more than 1.2% of its pages, so on the real corpus escalation on failure is cheap: the dearer route would see about one page in 154.

## 6. Vision OCR's page kind, a label no model gives

The Vision OCR lab's page sorter (`Recogniser.pageKind` in its `Sources/Recogniser.swift`) calls a page newspaper, photograph, handwriting or other from Apple Vision's reading of it: the number and width of its lines, the colour and lighting of the paper, and the shape of the ink along each line. It runs on the Mac, with no model and no paid call, so it can route a page before anything reads it, and it does not depend on the route being judged. Run with `scripts/segbench/vision_kind/run.sh` on the panel's originals and the bulk pilot's pages, as the app judges a page (the differences are in that tool's header); a newspaper or handwritten page outranks a photograph, so a photographed letter in a hand is handwriting.

On the 96 accuracy pages, against the truth's kind:

| Vision's kind | pages | handwritten | mixed | printed | typewritten | easy | middle | hard | mean NES of all routes | route failures |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| photograph | 57 | 2 | 1 | 15 | 39 | 24 | 17 | 16 | 93.76 | 46 |
| handwriting | 15 | 14 | 1 | 0 | 0 | 0 | 5 | 10 | 90.13 | 8 |
| other | 24 | 0 | 0 | 13 | 11 | 8 | 10 | 6 | 93.75 | 7 |

It calls 15 pages handwriting, 14 of them handwritten in the truth (1 mixed), and finds 14 of the truth's 16 handwritten pages. The models' own labels, for comparison: the 25 routes that label a page say handwritten on 7 to 16 of those 16 pages, and are right 90% to 100% of the times they say it. Typed and printed pages are photograph (54) or other (24, a page whose light reads as a scan's): the sorter separates handwriting and newspapers from the rest and says nothing about typewritten against printed. The pages it calls handwriting are hard ones, 10 of 15 in the hard third, so it predicts difficulty before anything reads the page.

**As a flag for a poor reading** (part 5), Vision's handwriting call has AUC 0.51 to 0.68 across the cheap readers, against 0.57 to 0.70 for the readers' own labels. Poor readings are spread over typed and printed pages too, so no kind label can find most of them.

**As a routing rule** (part 4's cascades, with a fifth family): the pages Vision calls handwriting go straight to the second route, unread and unpaid by the first, and the first route's failures follow them. Chosen on half the pages and scored on the other half, against escalation on failure alone: +0.45 at $0.5, -0.11 at $1, +1.42 at $2, +0.11 at $5 NES. The best such cascade on all pages at $1 per 1,000: Qwen3.8 Flash → Qwen3.6 27B (Vision's handwriting pages straight to Qwen3.6 27B), 95.22 NES for $0.83.

### On the real corpus

FarmShare's bulk pilot pages (2,000 random corpus pages; the model's kind label is Qwen3.6 27B's own, and a failure is a reply that ran to the token cap). There is no truth here, so this says how the two labels relate and where failures fall, not which label is right.

| Vision's kind | pages | model said handwritten | model said mixed | model said printed | model said typewritten | failed | failure rate |
|---|---:|---:|---:|---:|---:|---:|---:|
| newspaper | 12 | 1 | 0 | 9 | 2 | 0 | 0.0% |
| photograph | 1,532 | 31 | 141 | 366 | 994 | 12 | 0.8% |
| handwriting | 151 | 111 | 9 | 8 | 23 | 1 | 0.7% |
| other | 305 | 1 | 17 | 104 | 183 | 0 | 0.0% |

Vision calls 151 pages handwriting and the model says handwritten on 144; they agree on 111. 1,674 of the 2,000 pages read as photographs by their light and colour (a handwritten or newspaper page is counted under its own kind above). Failures are too few (one page in about 150) to say whether any kind fails more often. Vision's pass took about 30 minutes for the 2,000 pages and the panel's 99 together, five processes at once on the 18 GB M3 Pro.

## A proposed routing rule (a proposal, filed as W41.app-ocr-cascade; not built)

1. Read every page with a cheap reader first.
2. Send a failed page to a stronger route. This is the measured, robust gain (part 4), and on the real corpus it costs little because few pages fail.
3. Optionally, read the page with a second cheap reader (or compare the word count with Apple Vision's, which is free) and send pages where they disagree to the stronger route. It catches most poor readings, at the second reader's cost plus the pages escalated; on these pages its gain over step 2 alone was not consistent (part 4), so it wants a larger test before it is the default.
4. Where accuracy matters more than price, one strong reader alone is still the best single choice.

Vision OCR's page sorter (part 6) is not part of the rule: sending its handwriting pages straight to the stronger route did not gain at every paid budget on unseen pages, so on these 96 pages it is a free label and a predictor of difficulty rather than a routing step.

## Limits

96 pages from one corpus; truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash before it was adjudicated, so it may lean toward those families. Difficulty is measured by the same routes that are ranked, with the judged route left out. Most routes failed a handful of pages or none, so failure rates and where failures fall are anecdotes. The cascade frontier is chosen on the same pages it is scored on; the split-half column is the honest figure. Prices are standard, not batch.
