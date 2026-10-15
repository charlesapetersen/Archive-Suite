# W41 — the answers

W41.report, 2026-10-15. This page answers the owner's four questions from the transcription and segmentation
bake-off (`SUITE_TODO.md` §"transcription and segmentation bake-off on OpenRouter"), in order. Every figure comes
from a result file in this folder, and each section names its file. The changes it recommends for the app are at
the end. Each one is filed as its own queue item. Nothing is built here.

## What every figure here rests on

- **Transcription:** 100 truth pages drawn from 33 collections (one, p038, later excluded, leaving 99) of the owner's corpus (`ocr-truth.md`). 96 of them
  are scored for accuracy. The other three are the Michael Young letters, which count only as agreement with the
  drafters. The score is NES, from 0 to 100, where 100 is a character-perfect reading
  (`ocr-panel-local.md` §Scoring).
- **The truth leans toward two models.** Claude Opus 5.5 and Gemini 3.8 Flash drafted it. The owner then settled
  the spans where they differed. Spans where both drafts agreed were never reviewed, on every page, so they favour those two
  families, and Gemini 3.8 Flash itself most of all.
- **The samples are small.** One corpus and about 100 pages. A gap of one or two points between models is not a
  ranking. Some groups, like forms and tables (4 pages) or mixed writing (2 pages), are only anecdotes.
- **Segmentation:** five ground-truth boxes, 914 pages in all. The approaches were fitted on three of them and
  scored once on the other two, the locked Stanton and RG 165 boxes (363 pages). The open-weight models were run
  on one box, Deaver (149 pages).
- **Prices:** the transcription costs are the charges measured on each pinned route (Mistral OCR at Mistral's own
  published $4 per 1,000); segmentation costs use list prices read 2026-10-05 to 2026-10-11. Gemini 3.8 Flash is on an introductory
  price until 31 Dec 2026, and its cost doubles after that.
- **Hosted is not local.** Every open-weight transcription score below was measured on a provider's server, at bf16
  or fp8. None was measured on a Mac or on FarmShare. (Earlier on-device 4-bit runs exist for segmentation only, with
  models of 4B-12B, which scored 47-57% on Deaver.)

## 1. Users with more memory: what the app should offer

Source: `ocr-panel-local.md`, scored on the 96 accuracy pages. The memory figures are estimates: the model's
weights × 1.15, plus 4 GiB for the runtime and 4 GiB for macOS. They are not tested fits.

| Mac | model to offer | memory it needs (est.) | NES, hosted | where it falls short |
|---|---|---:|---:|---|
| 18 GB (ours, M3 Pro) | **Qwen3-VL 8B, 4-bit** | 12.7 GiB | 91.81 (bf16) | handwriting 84.8, forms 72.3 |
| 32 GB | **Qwen3.6 27B, 4-bit** | 22.9 GiB | 94.28 (fp8) | 4-bit quality unmeasured |
| 32 GB, for speed | Qwen3.6 35B-A3B, 4-bit | 27.3 GiB | 93.02 (fp8) | handwriting 88.8 |
| 48 GB | **Qwen3.6 27B, 8-bit** | 37.8 GiB | 94.28 (fp8) | Mac 8-bit quality unmeasured, expected near fp8 |
| 64 GB | Qwen3.6 27B, 8-bit, or 35B-A3B, 8-bit | 37.8 / 46.5 GiB | 94.28 / 93.02 | nothing bigger reads better |

For comparison: Apple Vision, the app's free on-device route, scores 81.34. Gemini 3.1 Flash-Lite, the app's
current default, scores 91.61. Claude Sonnet 5.5, the best on any panel, scores 96.47.

- **18 GB.** Qwen3-VL 8B is roughly as good as the current paid default, and about 10 points above Apple Vision.
  On handwriting it falls to 84.8, against Apple Vision's 57.9, and handwritten pages still read better in the
  cloud. Qwen3.5 9B also fits, but it misses 9.4% of words against Qwen3-VL 8B's 3.65%.
- **32 GB and up.** Qwen3.6 27B is the best open-weight reader measured anywhere in W41. It beats both open giants
  on the cloud panel, if only by 0.3 points: Qwen3.5 397B scored 93.98 and Qwen3-VL 235B 93.95. Typewritten pages, the most common kind
  in this corpus, score 95.5 with it. Printed pages score 94.8, handwritten 92.1, and the four forms and tables 96.2.
- **More memory buys precision, not a bigger model.** Bigger models did not read better: on segmentation Qwen3.5 122B
  scored below Qwen3.5 27B (84.4% against 95.0%), and the 235B and 397B scored below it on OCR. What 48 or 64 GB buys is running the 27B at
  8-bit, the nearest a Mac gets to the fp8 that was measured (a Mac's 8-bit build is a different format, so its
  score is unmeasured too, but expected close).
- **The 4-bit penalty is not known.** OpenRouter served no 4-bit build of these models for transcription. The one
  comparison available is the 35B-A3B on segmentation, which lost 3.6 points going from fp8 (DeepInfra) to fp4
  (Darkbloom, the one fp4 build offered) (`local-models-Deaver.md`); fp4 is not the same format as a Mac's 4-bit.
  So a 4-bit 27B should score somewhat below 94. How far below is what `W41.mac-local-measure` finds out, for the
  8B, on our own Mac.
- **Resolution matters more locally.** At half resolution most models stayed within about two points (the 20-page
  ladder in `ocr-panel-local.md`). At a quarter, every Qwen model fell to about 58-72, while Gemini Flash-Lite held at
  89.7. So a local model needs enough pixels per letter: on these photos, about half of the native size, capped at
  2400 px, was enough. The ladder's 20 pages were the largest photos, so this is a rough guide.
- **Speed is an estimate, not a measurement.** A Mac's speed generating text is limited by its memory bandwidth
  divided by the size of the weights it has to read. By that arithmetic:
  - Qwen3-VL 8B at 4-bit on our M3 Pro (150 GB/s): roughly 30-60 seconds a page, or about 60-120 pages an hour.
  - Qwen3.6 27B at 4-bit on an M4 Pro (273 GB/s): roughly 1-2 minutes a page.
  - The 35B-A3B reads only about 3B parameters for each token, so it should be several times faster than the 27B.
  - A 546 GB/s M4 Max at 8-bit lands about where an M4 Pro does at 4-bit.

  For a folder of a few hundred pages these speeds are workable. For the whole corpus they are not, and that is
  question 4.

## 2. The paid hierarchy

Source: `ocr-panel-cloud.md`, with groups from `ocr-panel-cloud-groups.csv` and `ocr-panel-local-groups.csv`.
Scores are NES on the 96 accuracy pages. A failed reading counts as an empty page, so these scores include the
refusals.

| route | NES | words missed | cost per 1,000 pages |
|---|---:|---:|---:|
| Claude Sonnet 5.5, subscription (`claude -p`) | **96.47** | 0.72% | subscription (about $20 by API, from a 3-page pilot) |
| Gemini 3.1 Pro | 94.85 | 3.02% | $21.92 |
| Gemini 3.8 Flash | 94.47 | 2.99% | **$3.22** (about $6.40 after 2026) |
| Qwen3.5 397B (open, fp8) | 93.98 | 2.10% | $2.02 |
| Qwen3-VL 235B (open, fp8) | 93.95 | 2.40% | **$1.22** |
| GPT-5.4 Mini | 93.55 | 3.56% | $5.55 |
| Gemini 3.5 Flash | 93.48 | 4.08% | $6.23 |
| Mistral Large 4 | 93.15 | 3.16% | $2.69 |
| Gemini 3.5 Flash-Lite | 93.13 | 4.38% | $1.57 |
| Mistral OCR 4.1 (the app's own client) | 92.91 | 4.07% | $4.00 |
| GPT-5.6 Luna | 92.13 | 4.80% | $1.41 |
| Gemini 3.1 Flash-Lite (**the app's default today**) | 91.61 | 4.70% | $1.17 |
| Mistral Medium 3.5 | 90.65 | 5.60% | $7.29 |

GPT-5.6 Sol was not run: it was allowed only on the subscription, and Codex reported the workspace out of credits.

**The order to recommend for typical US archival documents:**

1. **Claude Sonnet 5.5**, for whoever has a Claude subscription. It scored highest overall, highest on printed pages and
   on the blurriest photographs, and it refused nothing. On the paid API it costs about $20 per 1,000 pages, six times
   Gemini 3.8 Flash. That figure comes from the three-page pilot, so it is approximate.
2. **Gemini 3.8 Flash**, as the paid default. It sits within a point of Gemini 3.1 Pro for a seventh of the price,
   and it scored best of any route on handwriting (96.0). It is a drafter of the truth, though, so its lead over
   the next rows may be partly flattery.
3. **Qwen3-VL 235B**, as the best value. Like Qwen3.5 397B (93.98, $2.02), it is not a drafter, so its score is
   less flattered than the Gemini and Claude rows, and it costs $1.22 per 1,000 pages, the same price as today's default for 2.3 more points. The app cannot reach
   it yet: the panel reached it on DeepInfra through OpenRouter, and the app has neither (`W41.app-openrouter`).
4. **Gemini 3.5 Flash-Lite**, the budget choice inside the Gemini key the app already uses. It is 1.5 points above
   today's default for $0.40 more per 1,000 pages.

**Where the order changes by kind of page:**

| kind of page (pages) | best | then | weakest of the paid leaders |
|---|---|---|---|
| typewritten (50) | Gemini 3.1 Pro 98.8, 3.8 Flash 98.7, Claude 98.6 | any leader, 95+ | Mistral Medium 94.7 |
| printed, typeset (28) | Claude 96.3 | Qwen3.6 27B 94.8, Qwen 397B 93.7 | Gemini 87-89, its refusals included (3.8 Flash 93.9 on the pages it answered) |
| handwritten (16) | Gemini 3.8 Flash 96.0 | Gemini 3.1 Pro 94.1, Gemini 3.5 Flash 92.9, Claude 92.4 | GPT-5.6 Luna 85.4, Mistral Medium 85.0 |
| forms and tables (4) | Qwen3.6 27B 96.2, GPT-5.4 Mini 95.8 | Mistral Large 93.7, Qwen 397B 92.8, Luna 92.6, Claude 92.5 | Gemini 71-75 |
| mixed (2) | too few pages to say | | |

- **Gemini refuses some printed text.** Every Gemini route failed the same two pages: printed, from 1900-1949, at
  high resolution, one of them a table. AI Studio ends the call with the finish reason "error" and returns no text
  on reprinted published text (`ocr-truth.md` saw the same on Google's AI Studio). That explains Gemini's dips on
  1900-1949, on tables and on the highest-resolution third, and most of its dip on printed pages: on the pages it
  did answer, Gemini 3.8 Flash scored 93.9 on printed, still below Claude (96.3) and Qwen3.6 27B (94.8). So for Gemini the fix is to send a refused page to a second model, not to
  avoid Gemini for printed work (`W41.app-ocr-default`).
- **Period.** Apart from those refusals, one pattern: on pages from before 1900 (11 pages) the Gemini Flash models
  score 93-94 against Claude's 99.6 and Gemini 3.1 Pro's 98.3. Undated pages score 98-99.7 on every leader.
- **Quality of the photograph.** On sharpness, the blurriest third costs the leaders 1-5 points against the
  sharpest third. Claude loses the least (95.8 there).
- **Resolution.** This was measured on the local panel's 20-page ladder only, where the one Gemini model was 3.1
  Flash-Lite. Half resolution costs most models under two points (Flash-Lite lost five). At a quarter, Flash-Lite held
  at 89.7 and Gemma 4 31B at 86.0, while every Qwen fell to about 58-72. For low-resolution photographs Gemini is the
  likely choice, but no other Gemini model was tested at reduced resolution.
- **Size of the original.** Not measured. The truth table has the photograph's pixel size but not the paper's size.
  A large original photographed whole gives the same few pixels per letter as a low-resolution photo, so the
  resolution finding is the nearest guide.

## 3. Segmentation

Sources: `options.md`, `cheap-models.md` and `local-models-Deaver.md`.

| approach | pages in an exact document, no checking | boundaries to check per 100 pages | right after checking | unflagged errors per 500 pages | cost per 1,000 pages |
|---|---:|---:|---:|---:|---:|
| Gemini 3.8 Flash only | 88.8% | 24.2 | **100.0%** | **0** | **$3.61** ($1.81 batch) |
| Claude Sonnet 5.5 only | 87.0% | **10.2** | 97.3% | 4.1 | $16.93, or about half a five-hour window by subscription |
| ChatGPT only | 92.4% | 79.1 | 100.0% | 0 | $14.51 |
| GLM-5.3 Flash, at the 98% bar | 82.1% | 33 | 98.5% | 1 error in 363 pages | $1.16 |
| Full manual | — | 86.8 | 100.0% | 0 | none |

The table is scored on the two locked test boxes (363 pages). The GLM row comes from `cheap-models.md`, with its
checking level fitted as `options.py` fits one.

- **The best approach is Gemini 3.8 Flash only.** It asks for 24 checks per 100 pages (about 28% of the boundaries), and after
  that check it left nothing wrong on the test boxes. Claude asks for less than half as many checks, but it let 3
  errors through. Combining models adds little: they mostly make the same mistakes.
- **Cheaper models do not segment well enough to replace Gemini.**
  - GLM-5.3 Flash matched Gemini's 97.9% on the Deaver screen, then fell to 82.1% on the test boxes.
  - GPT-5.6 Luna and Qwen3.5 Flash fell the same way: Luna to 84.5% and Qwen to 77.6%.
  - Only GLM is worth offering, and only as a budget option for a user who checks everything flagged: a third of the
    price, at 33 checks per 100 pages instead of 24.
- **Open-weight segmentation is not closed.**
  - Qwen3.5 27B, the size a 32 GB Mac could hold at 4-bit, scored 95.0% on Deaver at fp8, against the cloud's 97.9%.
  - That is one box, and the cheap models' fall shows how far a Deaver figure can drop on the other boxes.
  - It has not been run on the test boxes, at 4-bit, or on a Mac.
  - The app should not offer local segmentation yet. If the owner uses FarmShare, `W41.farmshare-seg` runs it there.

## 4. The bulk route: the whole corpus

The corpus is about 100,000 archival photos and about as many scanned newspaper pages. Photo costs below use the
measured cost per page. Newspaper costs are **estimates**: a broadsheet is taken as about 10,000 image tokens (Qwen's
processor at a 3584 px cap) and about 4,900 output tokens (from NewsBench's average of 3,603 words a page;
`farmshare/README.md`), at list prices. Gemini counts an image as far fewer tokens (about 1,400 for a photo), which
gives the lower end of its ranges. The newspaper count of about 100,000 is the owner's own figure. For
broadsheets, every whole-page route is also expected to read worse than a layout-first one (below).

**FarmShare has not been run.** `W41.farmshare-run` waits on the owner. So every FarmShare figure here is the
plan's estimate, and the run must confirm it.

Times use the mean seconds a call measured in the cloud run's ledger (private cache `calls.jsonl`).

| route | 100k photos | 100k newspaper pages (est.) | time | per 1,000 photo pages |
|---|---|---|---|---|
| **Paid, best value**: Qwen3-VL 235B (93.95) | **$122** | about $600-1,100 (the pinned provider charged below list) | about 3 days at ten at once (28 s a call measured); more at once is faster, within the provider's limits | **$1.22** |
| **Paid, default**: Gemini 3.8 Flash (94.47) | $322 (perhaps $161 by batch, untested for OCR); about $640 after 2026 | about $1,900-2,600 | under a day at ten calls at once (5 s a call measured) | $3.22 |
| **Paid, top**: Gemini 3.1 Pro (94.85) | $2,192 | about $6,000-9,000, reasoning included | about 2 days at ten at once (14 s a call) | $21.92 |
| **Subscription**: Claude Sonnet 5.5 via `claude -p` (96.47) | about 5 weeks of the owner's whole weekly Claude window, doing nothing else (the weekly meter is coarse: anywhere from a few weeks to ten) | several times that (more output a page) | set by the weekly limit, not by speed | about half a five-hour window, about 5% of a week |
| **FarmShare**: Qwen3.6 27B fp8 (94.28 hosted) | **$0**, 55-132 GPU-hours | $0, 171-461 GPU-hours whole-page | about 14-33 h of wall time for the photos, at 4 GPU jobs | $0; 0.55-1.3 GPU-hours |

**How the subscription figure is made.** It is an inference from two measurements, not a measurement of its own:

- The OCR run's own token counts (in the private cache's per-page replies) give a notional list price of $0.051 a
  page: about 48k input tokens a page, mostly Claude Code's own harness, of which about 33k were cache reads and 15k
  cache writes, plus about 720-820 output tokens. The rates used are Sonnet 5.5's $2/$10 per million, with cache
  writes at 1.25× and cache reads at 0.1×. Segmentation's notional price was nearly the same, $0.0506 a page, so its
  meter ratio should carry over.
- The segmentation calibration on the owner's plan measured about one point of the five-hour window per $0.98 of
  notional price (`usage.md`).
- Together: about 5% of a five-hour window per 100 pages, and about 0.5% of the week. The weekly figure is one meter
  step, so it is coarse.
- Claude Code's terms also say that the advertised limits of Pro and Max plans "assume ordinary, individual usage"
  (the owner's seat is an enterprise plan, but the spirit is the same). A 100,000-page job is not that. The
  subscription route suits a folder, not the corpus.

**Which model on FarmShare.** Qwen3.6 27B at fp8 on one L40S, the card's 48 GB holding about 29 GB of weights.

- It is the best open-weight reader on either panel. It is within 0.2 points of Gemini 3.8 Flash, above Qwen3-VL
  235B, and above the app's default.
- Its speed option is Qwen3.6 35B-A3B. It is about 2.5-3 times faster (21-47 GPU-hours per 100k photos) for 1.3
  points less.
- The four-card node is not worth it: the giants do not fit at fp8, and on these panels bigger did not read better
  (`farmshare/README.md`).

**Newspapers are the open part.** On NewsBench, the Vision OCR lab measured whole-page models at 0.75-0.82, and
layout detection followed by GLM-OCR on each region at 0.970 (`~/Claude/vision-ocr/OCR-NEWSBENCH-2026-10-07.tsv`).
So whole-page FarmShare figures for broadsheets are a floor, and the route to build for them is
`W41.farmshare-news-layout`. The clippings in the archive photos are a different case: the 27B scored 93.71 on the
13 clipping pages.

**What the FarmShare run must confirm:**

1. **The score at FarmShare's build.** The panel's fp8 build came from Chutes. FarmShare would load the official
   `Qwen3.6-27B-FP8`, and the two may not be the same.
2. **Pages an hour per GPU.** The estimate of 760-1,816 assumes 20-40% of the card's peak compute.
3. **Whether the fp8 checkpoint loads on the L40S at all.** If it does not, the `-dyn` preset is the fallback.
4. **The GPU wall-time limit and the scratch quota.** The FarmShare docs give neither.
5. **The newspaper score on NewsBench.**
6. **Whether this project qualifies.** FarmShare is for coursework and unsponsored research, and only the owner can
   decide whether this is that.

**Set side by side, per 1,000 photo pages:**

| route | cost | NES |
|---|---|---:|
| FarmShare | $0 and about an hour of GPU time | 94.28 hosted, to be confirmed |
| Best paid value (Qwen3-VL 235B) | $1.22 | 93.95 |
| Paid default (Gemini 3.8 Flash) | $3.22 | 94.47 |
| Subscription (Claude Sonnet 5.5) | about half a five-hour window | 96.47 |

For the whole photo corpus the paid route costs about $120-320. That is small next to the scale of the collection,
so FarmShare's real advantage is on the newspapers, where the paid figures run to the thousands.

## The changes this recommends for the app, each filed as its own queue item

1. **`W41.app-ocr-default`**: make Gemini 3.8 Flash the default OCR model in place of 3.1 Flash-Lite. Add it, and
   3.5 Flash-Lite, to the model list with current prices. When Gemini ends a page with no text (its refusal of
   reprinted published text), read that page with a second route the user has a key or login for, instead of
   failing it. `ocr-truth.md` found that Google's Vertex endpoint answers those pages, so that is one candidate.
2. **`W41.app-ocr-hierarchy`**: show the hierarchy above in the model picker, as measured guidance by kind of page:
   - handwriting: Gemini 3.8 Flash;
   - printed text and forms: Claude, or an open Qwen;
   - typewriting: any leader;
   - low-resolution photographs: Gemini.

   Each line carries its NES and the "one corpus, about 100 pages" caveat.
3. **`W41.app-openrouter`**: add OpenRouter as a provider, one key with a pinned provider and precision per model.
   It reaches Qwen3-VL 235B, the best-value reader at $1.22 per 1,000 pages, and Qwen3.6 27B. It also adds GLM-5.3
   Flash as the budget segmentation option, shown with its 33 checks per 100 pages.
4. **`W41.mac-local-measure`**: run Qwen3-VL 8B at 4-bit (MLX) on the 99 truth pages on our 18 GB Mac. It measures
   the 4-bit penalty against the hosted bf16 score (91.81 on the 96 accuracy pages), and the seconds a page. No money.
5. **`W41.app-local-models`** (waits on 4): a local-server route for open-weight models, recommended by memory size
   as in the table under question 1. The app's `OpenAICompatibleClient` already takes a base URL.
6. **`W41.app-seg-default`**: when a Gemini key is set, the segmentation approach picker preselects "Gemini only". It
   stays manual otherwise. Claude stays the fewest-checks choice for a subscriber.
7. **`W41.app-farmshare-import`** (waits on `W41.farmshare-run`): yes, the app should be able to take in a FarmShare
   bulk run's text, but only if the owner uses FarmShare and its truth run lands near the panel. It would match each
   `<image>.txt` and its `_meta` JSON to the page it came from, and bring the text in as that page's transcription.
   It writes to Processor output, never into the real corpus.
