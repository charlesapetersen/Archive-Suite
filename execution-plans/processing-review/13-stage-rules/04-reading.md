# 04. Reading: OCR and HTR, all scripts and hands (Phase 4 rule note, draft)

Draft of 2026-11-06 for the owner's walk. Strand C. Unit: pages. Every figure names its file; [M] measured, [I]
inferred, [?] unverified. Every Apple Vision figure here is the macOS 27.2 reading (W46.vision-27-swap,
`vision-27-reread.md`); no 26.6 Vision figure is used.

## 1. Stage and question

The stage turns a page image into its text. The user chooses which reader (or chain of readers) reads which kind of
page, within the keys, plans, cluster and Mac memory they have.

## 2. Is there a choice?

Yes. Offered readers run from 96.85 (Gemini 3.1 Pro) to 83.61 (Apple Vision) answered NES on the owner's 96, and
from 76.87 (Gemini 3.7, all 895) to 39.3 (Vision, its 320 Latin pages) strict on the public set, at prices from $0 to
$21.92 per 1,000 pages; no route is best on every kind at every price [M, `ArchiveOCRBench/data/panel-data.json`
headline; `ocr-scorers.json`]. The routes are the rows in section 4 and the cascade rows after them.

## 3. The rule for the settings layer

**What the sheet shows.** "Reading. Each route's accuracy on the owner's 96 test pages (typewritten, printed,
handwritten) and, where it was run, on public pages of the same kind. Figures within the bench's tie rule are shown
as ties. The 96's truth was drafted by Claude and Gemini models, so close rows among those families are provisional,
and the handwriting figures are agreement with that truth more than proof."

**Metric.** `nes_answered`: NES on the pages a route answered, over the 96 with p081 apart (95 pages), with the
failure count beside it, split into the provider's (transport) and the model's own (cap, refusal, empty) failures, as
the bench counts them (`ArchiveOCRBench/build.py`, `MODEL_FAILURES`); strict NES (a failure as 0) is shown beside it
[M, panel-data.json `headline`; W46.ocr-rescore-offline, R-6]. Higher is better.
The solver ranks on answered NES when a fallback is configured for failed pages (the cascade or the loop fallback),
because a failed page then goes on to another reader; with no fallback a failed page is an unread page and the
solver ranks on strict NES [I, from the owner's framing of 2026-10-15 in `difficulty.md` and the OCR-2 fix]. Per kind
the bench has strict figures only (`charts.<kind>`), and the hand figure is `ocr-hands-rescore.md`'s "after" column.

**Tie rule.** A gap is a tie only when the paired gap is under twice the larger rerun range of the two routes
(`ocr-rerun-noise.md`, "The tie rule"); the paired 95% interval is shown beside the figure but makes no tie (the
owner, walkthrough 2026-11-11, W46.pairs-redecide-owner-ok: floor only, as `12-settings-design.md` §3.3 reads). Floors, each already twice a measured range: a hosted
route 0.49 points (twice Gemini 3.7 Flash's rerun range of 0.24, lent to every hosted route without its own rerun); a
local greedy route 0.00, so any paired gap separates two of them (Qwen3-VL 8B 4-bit byte-identical across two runs 15 days
apart); per kind twice the kind's own range (handwritten hosted 0.60, twice 0.30, `ocr-ppocrv6-hands-paid.md` Noise);
on the 895 no floor makes a tie, so a pick there takes the stratum's leader and the interval makes no tie either (the
owner's "the interval makes no tie", applied to the 895 picks by W46.pairs-redecide); the interval (R-3, the matrix's
895 `tie` flag) decides only whether a stratum route earns a row, as Ling3 Flash VL's N5 pair did. The rerun floor
is a route's own property, not the 96's, so the hosted 0.49 applies on the 895 too as each route's own floor; it changes
no pick today (no cluster runner-up within 0.49 in L4, L9 or pooled L1-L3), and L3 and N6 are the groups where a
cluster runner-up sits within it (`ocr-pair-matrix.md` §The tie per pair; pass 14, P14-5).
The bench pairs every reading row that has per-page scores with every other (`ocr-pair-matrix.md`, W46.ocr-pair-matrix
and W46.pair-matrix-cover): on the 96 over all pages, per kind (typewritten, printed, handwritten, each with its kind
floor: 0.42, 0.24, 0.60 hosted, a Mac pair 0.00) and on hands16; on the 895 per stratum and pooled L1-L3. The
solver reads each tie from the pair's entry; `settings_routes.py --check` fails when a row with per-page scores has
none. The rows without per-page scores (Apple FM 27, the PP-OCRv6 kraken blla route, the kraken specialists, the
cascades) keep the floor alone and "pair not measured". A tie goes to the cheaper, then the faster route
(`12-settings-design.md` §3.3); the picks in section 9 were re-decided from the matrix under the floor-only rule
(W46.pairs-redecide), each naming its pair entry.

**Kind rules.**
- Handwritten pages are ranked on `hands16` and, where the route read them, the public L1-L3 (independent truth);
  the 16-page chart alone is labelled "agreement with the drafters" (OCR-1).
- Non-Latin scripts (N1-N6): Apple Vision is unmeasured there (the bench ran it on the 320 Latin-script pages of the
  440 only, "Vision's script filter", `vision-27-reread.md`), so it is not offered on them [I]; a route with no
  reading of a stratum shows "not read", never 0.
- Newspapers and multi-column clippings: the layout stage (PP-DocLayoutV3 regions) runs first for every reader, as
  note 03's settled pick has it (14-owner-calls.md section 2; the gain is nil, not negative, for large readers on 15
  pages). It is required, not only allowed, for the routes measured to fail L9 whole page: GLM-OCR (whole page 29.2,
  cap or empty on 9 of 15, `layout-photo.md`) and PaddleOCR-VL (L9 0.0, 0 of 15 answered for 1.6 on Sherlock,
  `ocr-scorers.json`) [M]. No model-size cut is used: small specialists read L9 whole at LightOnOCR-3 4B 92.48 and
  Xiaomi-OCR-0 95.17 (15 of 15 each); the "under about 10B" cut is `C-ocr.md` §6's literature reading [I]. Pass 4's
  qualification holds: the measured gain is an operational GLM-OCR comparison under per-crop caps, not an
  output-budget-matched proof that layout improves transcription (`2026-11-01.md` §1). Never on handwriting or
  registers (`layout-photo.md` rule 2).
- The free default (owner call 4): typed and printed pages read with Apple Vision; handwritten pages on a 16 GB Mac
  get LightOnOCR-3 4B 8-bit proposed as a download, and a user who declines, or a smaller Mac, gets them flagged
  "needs a download or a key", not read; a page Vision returns empty for is flagged, never skipped, on every profile.
- Forms and registers (L4): no route reads them well open; the sheet shows the L4 figure beside the route.
- Cyrillic (N2): the best figure is 27.06 (Xiaomi-OCR-0, Sherlock); the sheet says no route reads it well.
- The macOS 27 on-device model is never the app's pick (42.4 against Vision's 83.1, r1-foundation.md); since owner
  call 15 (2026-11-19, W47.wh-readers-lost) it is a lower-scoring row, offered at the Advanced level with its figures.
- Lower-scoring rows (owner call 15, W47.wh-readers-lost): a route a row of its family dominates on the 96 (below) is
  a row with a `lower-scoring: …` condition naming what beats it. It sits at the Advanced level with its figures and is
  never a default, the solver's pick, a suggested alternative or the Improve OCR suggestion; chosen on the card, it is
  what the stage reads with (the solver keeps it only where `onlyRoutes` names it).
- Image-grounded correction is off by default and optional in Advanced Reading settings (owner call 15,
  W47.wh-post-correction). On middle-accuracy readings it tied re-reading with the 27B on the 96 (−0.42,
  95% interval −1.47 to +0.64) and gained +1.47 (+0.55 to +2.63) on 120 public readings. It worsened
  4 of 57 and 10 of 120 starting readings. The test ran on Sherlock FP8. The app uses the pinned
  Qwen3.6 27B route at OpenRouter (Chutes) for eligible standard Process Files pages and keeps the
  initial reading on failure or truncation. The benchmark band needed checked transcriptions, so it
  does not select pages at runtime. There is no text-only correction. A log-probability score flags a
  reading for checking (`ocr-postcorrect.md`, `ocr-logprob.md`).

**Fallback when the chosen route fails on a page.** A reply at the token cap is a failure, stopped early. Shipped
today: the cascade (`OCR/OCRCascade.swift`, off by default) re-reads a failed page (cut off at `length`,
`unparsable`, 500 or `api_error`, a Gemini refusal) with the route the user set in "Escalate failed pages to";
transport errors, timeouts, rate limits, the gateway, the Local Agent and Apple Vision as first reader are never
escalated; a failed escalation fails the page as `CascadeExhausted`, never auto-retried; opt-in, a page whose word
count differs from Apple Vision's by more than 1.5x is escalated (`SUITE_TODO_DONE.md`
W41.app-ocr-cascade; `ArchiveProcessor/CLAUDE.md`). As a setting (owner call 5): each measured cascade is a route row,
and the solver picks it when it beats the single routes within the user's limits; failure is its only trigger and
the word-count trigger stays opt-in. A local VLM's loop falls to a second reader or kraken PP-OCRv6
on lines, never to a half-size retry (351 of 1,573 answered, `loop-rerun-20261021.md`); the order is a solver
setting, not a measured optimum (7.4, decided). When every route fails, the page is left unread and flagged.

**When the stage must not run.** Nothing measured says a page kind must skip reading. The 19 pages the 96's draw
replaced (under 20 Vision words) include 4 handwritten pages Vision could not read, besides 2 images, 2 tree diagrams,
1 clipping and 10 untagged pages (`ocr-truth.md`), so "no Vision text" is not "no text" and must not skip the stage [M].

**Fields for the table.** `metric`: {"id": "nes_answered", "label": "NES on answered pages, failures beside",
"higher_is_better": true}. `kinds`: typewritten, printed, handwritten, mixed (2 pages, never ranked), forms (L4),
newspapers (L9), clippings (no figure), nonlatin (N1-N6), early_modern_hands (L2, L5-L7), early_print (L8).
`noise`: the table's `noise.reading`, written by `settings_routes.py`: on the 96 a paired gap under the floor only
(hosted 0.49, local greedy 0.00, per kind 0.42, 0.24, 0.60 hosted; the interval shown, no tie); on the 895 the
stratum's leader for a pick, the interval only for a row; each pair's entry in `ocr-pair-matrix.json`. `fallback`: "fail-and-flag (CascadeExhausted)".

## 4. Table rows

The rows below were generated from the bench's files by a copy script (no figure computed; values rounded to two
places from the raw value the `source` holds); since W46.settings-routes-table that script is part of
`ArchiveProcessor/scripts/segbench/settings_routes.py`, which builds the single-route rows from the files themselves
(the cascade rows below are read from this section). `overall` is the headline (answered, p081 apart, with the paired
difference from Qwen3.6 27B); `kinds` is strict per kind on the 96; `hands16` is the hand sheet's corrected score;
`public` gives [strict, answered, answered/n] by stratum from `ocr-scorers.json` (one current scorer, 27.2 Vision);
`public_L1-L3` is `ocr-ppocrv6-hands.json`. They replace `settings-design/figures.json`'s "ocr" rows, whose overall
figures mix strict and cluster-run scores and whose hand and public joins cross runs (section 8, item 2). Mac rows
show no public figure of their own; their cluster twins' rows do (owner call 7.5).

The single-route rows are not copied here: they are the reading rows of `ArchiveProcessor/segbench-results/settings-routes.json`,
which `settings_routes.py` writes and `--check` holds to the bench files. This note kept a hand copy of them until
2026-11-20 (doc-fix: it was 85 KB, two-thirds of the note, and a second place to keep current); that copy is in git
history before then. Line numbers this section cited before 2026-11-20 refer to that version.

Cascade rows (R8). This note owns them (owner call 5): a cascade is a route like any other, ranked on the reading
chart beside the single routes, and note 10 points here. Simulated from the measured readings of the 96 by 29 routes,
failures as 0 on all 96 pages (p081 included), standard prices; `stages` and `trigger` extend the schema for R8 rows
(item 6). Each row's `value` is the split-half figure, the honest one: chosen on half the pages and scored on the
other half (`ArchiveOCRBench/difficulty.md` §4, "the split-half column is the honest figure"); the all-pages figure,
chosen and scored on the same pages, is a caveat. Costs are `difficulty.md`'s "$ / 1,000", not `figures.json`'s
(item 1).



```json
[
{"id":"casc-free-fail","name":"Qwen3-VL 8B 4-bit (Mac), failures to Qwen3.5 9B 4-bit (Mac)","family":"mac","status":"measured","stages":["qwen3-vl-8b-mlx4","qwen3.5-9b-mlx4"],"trigger":"fail","needs":{"mac":true},"figures":{"overall":{"value":92.67,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":4,"split_half":"93.55 -> 92.67","single_route_split_half":"Qwen3.5-9B 4-bit 91.96 -> 91.89","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 0, escalate on failure","attribute":"NES; chosen on half -> other half","value":"93.43; 93.55 -> 92.67"}}},"cost":{"usd_1000_list":0.0,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 0","attribute":"$","value":"free"}},"time":{"per_unit_s":null,"measured":false,"measured_on":"two Mac readers; escalated pages pay both (difficulty.md §4)","source":null},"memory":{"peak_gb":7.64,"measured_on":"the larger stage, one model loaded at a time [I]","source":{"file":"ArchiveProcessor/segbench-results/ocr-mac-local.md","route":"qwen3-vl-8b-mlx4","attribute":"MLX peak memory max","value":"7.64"}},"caveats":["all 96 pages, chosen and scored on the same pages: 93.43, the flattered figure (difficulty.md §4)","[I] the app's cascade does not run Mac-to-Mac today: it escalates failures on the direct-provider path (SUITE_TODO_DONE.md W41.app-ocr-cascade)"],"kind_rules":[],"fallback":null,"conditions":["a Mac escalation stage in OCRCascade"],"app_route":null},
{"id":"casc-1-fail","name":"Qwen3.8 Flash, failures to Gemini 3.1 Flash-Lite","family":"cloud","status":"measured","stages":["qwen3.8-flash","gemini3.1-flash-lite"],"trigger":"fail","needs":{"key":["openrouter"]},"figures":{"overall":{"value":94.07,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":3,"split_half":"95.09 -> 94.07","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 1, escalate on failure","attribute":"NES; split half","value":"95.04; 95.09 -> 94.07"}}},"cost":{"usd_1000_list":0.64,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 1, escalate on failure","attribute":"$","value":"0.64"}},"time":{"per_unit_s":null,"measured":false,"source":null},"memory":{"peak_gb":0,"source":null},"caveats":["all 96 pages, chosen and scored on the same pages: 95.04, the flattered figure (difficulty.md §4)","Gemini is a drafter's family (OCR-1)"],"kind_rules":[],"fallback":null,"conditions":[],"app_route":null},
{"id":"casc-2-fail","name":"Qwen3.6 27B, failures to Gemini 3.8 Flash","family":"cloud","status":"measured","stages":["qwen3.6-27b","gemini3.8-flash"],"trigger":"fail","needs":{"key":["openrouter"]},"figures":{"overall":{"value":93.69,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":1,"split_half":"95.69 -> 93.69","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 2, escalate on failure","attribute":"NES; split half","value":"95.36; 95.69 -> 93.69"}}},"cost":{"usd_1000_list":1.97,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 2, escalate on failure","attribute":"$","value":"1.97"}},"time":{"per_unit_s":null,"measured":false,"source":null},"memory":{"peak_gb":0,"source":null},"caveats":["all 96 pages, chosen and scored on the same pages: 95.36, the flattered figure (difficulty.md §4)"],"kind_rules":[],"fallback":null,"conditions":[],"app_route":null},
{"id":"casc-2-vision-hands","name":"Qwen3.8 Flash, failures and Vision's handwriting pages to Gemini 3.8 Flash","family":"cloud","status":"measured","stages":["qwen3.8-flash","gemini3.8-flash"],"trigger":"fail+vision","needs":{"key":["openrouter"],"mac":true},"figures":{"overall":{"value":95.05,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":18,"split_half":"95.85 -> 95.05","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 2, Vision's handwriting pages sent straight on","attribute":"NES; split half","value":"95.81; 95.85 -> 95.05"}}},"cost":{"usd_1000_list":1.25,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 2","attribute":"$","value":"1.25"}},"time":{"per_unit_s":null,"measured":false,"source":null},"memory":{"peak_gb":0,"source":null},"caveats":["all 96 pages, chosen and scored on the same pages: 95.81, the flattered figure (difficulty.md §4)","Vision's sorter as a routing step did not gain at every paid budget (difficulty.md, routing rule); conditional on the 20-word Vision filter (P8-3)"],"kind_rules":[],"fallback":null,"conditions":["not built: the shipped cascade has no kind trigger"],"app_route":null},
{"id":"casc-5-fail","name":"Gemini 3.8 Flash, failures to Qwen3.5 35B-A3B","family":"cloud","status":"measured","stages":["gemini3.8-flash","qwen3.5-35b-a3b"],"trigger":"fail","needs":{"key":["openrouter"]},"figures":{"overall":{"value":94.84,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":2,"split_half":"96.56 -> 94.84","single_route_split_half":"Gemini 3.8 Flash alone 95.35 -> 92.82","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 5, escalate on failure","attribute":"NES; split half","value":"96.36; 96.56 -> 94.84"}}},"cost":{"usd_1000_list":3.24,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 5","attribute":"$","value":"3.24"}},"time":{"per_unit_s":null,"measured":false,"source":null},"memory":{"peak_gb":0,"source":null},"caveats":["all 96 pages, chosen and scored on the same pages: 96.36, the flattered figure (difficulty.md §4)","drafter-biased first stage (OCR-1)","its second stage, Qwen3.5 35B-A3B (OpenRouter, 92.82 answered), has no row of its own (section 4, not in the table)"],"kind_rules":[],"fallback":null,"conditions":[],"app_route":null},
{"id":"casc-disagree-0.5","name":"LightOnOCR-3 4B (Mac), checked against Qwen3.5 9B at 0.90, to Qwen3.8 Flash","family":"cloud","status":"measured","stages":["lightonocr-3-4b-mlx8","qwen3.8-flash"],"trigger":"disagree@0.90","needs":{"key":["openrouter"],"mac":true},"figures":{"overall":{"value":92.59,"basis":"strict, split half: chosen on half the 96, scored on the other half","escalated":32,"split_half":"95.61 -> 92.59","truth":"owner-96","source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 0.5, two cheap readers disagreeing","attribute":"NES; split half","value":"95.01; 95.61 -> 92.59"}}},"cost":{"usd_1000_list":0.44,"source":{"file":"ArchiveOCRBench/difficulty.md","route":"budget 0.5","attribute":"$","value":"0.44"}},"time":{"per_unit_s":null,"measured":false,"source":null},"memory":{"peak_gb":6.45,"source":{"file":"ArchiveProcessor/segbench-results/ocr-mac-local-hw.md","route":"lightonocr-3-4b-mlx8","attribute":"MLX peak","value":"6.45"}},"caveats":["all 96 pages, chosen and scored on the same pages: 95.01, the flattered figure (difficulty.md §4)","the most flattered family: on unseen pages +0.45 at $0.5, -0.63 at $1 against failure alone (difficulty.md §4)"],"kind_rules":[],"fallback":null,"conditions":["not built: the shipped cascade's only disagreement trigger is the 1.5x word count against Vision"],"app_route":null}
]
```

Not in the table: 18 of the 53 headline routes had no row (W46.ocr-rows-omitted, 2026-11-11, added five: the four cheap
hosted routes and `churro-3b-farmshare`; each of the 18 below has its stated reason). Since W47.wh-readers-lost
(2026-11-20, owner call 15) the fifteen dominated routes below, the four hosted and the eleven cluster, are rows with a
`lower-scoring` condition, offered at the Advanced level only; three remain without a row (`qwen3.5-27b`,
`paddleocr-vl1.5-farmshare`, `granite-docling-258m-mlx`) (panel-data.json `headline`, answered NES; prices
`routes.std`; cluster pages an hour `farmshare.truth`). "Dominated" means a row in the same family scores higher on
the 96 and costs no more (hosted) or reads more pages an hour (cluster).
- `qwen3.5-27b` (hosted, 95.86, 5th): 14 of 96 pages lost to transport errors, strict 81.73, so its answered figure
  rests on 82 pages; held out until a rerun answers the 96. The rerun is a paid hosted run (about $0.17 at its $1.80
  per 1,000 list), so it waits behind the paid-benchmarking hold in `execution-plans/paid-runs-deferred.md` (W43.sweep)
  [I].
- Rows since W46.ocr-rows-omitted: the cheap hosted routes, priced under every other hosted row, `gemma4-31b` 93.76
  ($0.38), `qwen3.5-9b` 93.38 ($0.25), `gemma4-26b-a4b` 92.38 ($0.41), `mistral-small-24b` 91.45 ($0.32), all 96
  only. A price cap under $0.60 now finds a hosted row.
- Dominated hosted routes: `qwen3-vl-8b` 93.85 ($1.49) and `qwen3-vl-30b-a3b` 91.79 ($0.98) by `qwen3.8-flash` 95.11
  ($0.60); `qwen3.5-35b-a3b` 92.82 ($0.83) by the same (it is `casc-5-fail`'s second stage); `mistral-medium3.5`
  90.94 ($7.29) by `mistral-large4` 93.25 ($2.69).
- Dominated cluster routes, all under `qwen3.5-9b-sherlock` (95.13, 3,898.9 pages an hour, one GPU) and slower:
  `qwen3.5-122b-a10b-farmshare` 94.67 (4 GPUs, 729.4), `ling3-flash-vl-farmshare` 93.81 (4 GPUs, 76.6),
  `qwen3-vl-8b-farmshare` 93.56 (1,105.5), `qwen3.8-27b-sherlock` 93.48 (2,886.8), `qwen3.8-27b-farmshare` 93.17
  (1,063.2), `glm-ocr-farmshare` 92.05 (3,463.2; its layout role is note 03's), `qwen3.5-4b-farmshare` 91.94
  (1,936.7), `nemotron-parse-2-sherlock` 86.87 (1,061.3),
  `unlimited-ocr-sherlock` 85.46 (202.8).
- Dominated by `paddleocr-vl1.6-sherlock` (90.89, 12,327.9 pages an hour): `lightonocr3-0.8b-farmshare` 88.04
  (5,527.3), `ppocrv6-medium-farmshare` 77.17 (8,106.9; its Mac form is `ppocrv6-kraken-blla`).
- Superseded: `paddleocr-vl1.5-farmshare`, 93.53 answered but 84.67 strict with 9 caps, by 1.6 (strict 88.98).
- `granite-docling-258m-mlx` 77.39: no public figure anywhere (P5-1).

Domination is judged on the 96 overall only. Item 10's check of the public strata (ocr-scorers.json, public895, NES
strict; each dominated route against every row's public figures in its family and against all rows): one dominated
route leads, `churro-3b-farmshare`, now a row. It is the best cluster route on seven strata of the 440 (L5 62.78
against LightOnOCR-3 4B 58.90, L6 69.45 against Infinity-Parser2-Pro 54.46, L7 53.85 against Xiaomi-OCR-0 43.93, L8
92.61, N1 69.19, N3 84.70, N4 57.88), and on L8 and N4 above Gemini 3.7 Flash's 89.83 and 48.65; it was trained on
CHURRO-DS, the source of those strata, so its row carries OCR-15 until item 8 counts the overlap. The other near miss:
`ling3-flash-vl-farmshare` N5 82.29 against `qwen3.6-35b-a3b-farmshare` 82.12: paired on the 40 N5 pages, +0.16
[−4.39, +4.86] strict and −0.75 [−5.20, +3.79] answered (n 38), and against the N5 leader `gemini3.7-flash-gw`
−1.72 [−6.76, +3.17], each a tie by the interval (the 895 has no floor; the earlier "under the floor" applied a 96
rule), so no row (four GPUs, 76.6 pages an hour; W46.pair-matrix-cover). The dominated hosted routes have no public run of their own.

R6, commercial document services: none found worth a row (still none after W47.wh-readers-lost: their figures are on 25
of the 96 only, not comparable to the rows' 95, and the app has no client for any of them). On 25 of the 96 Azure Document Intelligence read 89.6,
AWS Textract 86.6 and Transkribus Text Titan I 82.5, each under Mistral OCR 4.1's 92.5 on the same pages (Azure -2.9,
-6.3 to -0.2; Transkribus -10.0, -16.9 to -4.5; Textract -5.8, -13.4 to +1.5, a tie at n 25), at list prices of $10
and $19 per 1,000 for the first two (`r6-spot.md`; panel-data.json `r6_spot`) [M].

Fields used beyond 00-index.md's schema: `stages`, `trigger`; figure fields `strict`, `failures`, `vs_qwen3.6-27b`,
`basis`, `strata`, `empty`, `failed`, `unresolved_range`, `split_half`, `single_route_split_half`, `escalated`,
per-kind and per-stratum arrays; cost `openrouter_equivalent_usd_1000`, `gpu_hours_per_100k`,
`api_equivalent_usd_1000`, `plan_share`; time `pages_per_hour_per_gpu_set`, `gpus`, `mean_s`; memory
`whole_process_gb`; `needs.mac` and `needs.built_in` in place of `mac_gb`.

## 5. Caveats carried

- **OCR-1 (weakened, then done).** Gemini 3.8 drafted the 96's truth with Claude Opus 5.5. After the owner's blind
  hand sheet (114 places: truth stands 87, either 10, wrong 12), Gemini 3.8 Flash reads the 16 at 95.81, ties Gemini
  3.7 (+0.76, -0.60 to +2.89) and leads the other 48; against Claude Sonnet 5.5 (+3.31, +0.21 to +7.24) and Gemini
  3.1 Pro (+1.84, +0.03 to +4.27) the lead fails on the excluded or adverse treatment, so it is conditional
  (`ocr-hands-rescore.md`; pass 3, W46.ocr-audit-report-fix) [M]. Rule: every `hands16` figure carries the truth note;
  the public L1-L3 rank hands on independent truth; owner call 7.3.
- **OCR-2 (weakened, fixed by W46.ocr-rescore-offline).** Rows use answered NES with failures beside, provider and
  model failures apart (panel-data.json `headline`). The old "Sonnet highest at 96.47" is replaced: the top four on
  the 96 (Gemini 3.1 Pro 96.85, Gemini 3.7 96.76, Sonnet 96.48, Gemini 3.8 96.47 answered) tie (R-6).
- **OCR-3 (fixed by W46.ocr-rerun-noise).** The tie rule above. R-3's caveats hold: three Gemini runs make the range
  rough; per-kind ranges rest on 2-50 pages; Qwen's zero is determinism on one machine.
- **OCR-4.** p081 is apart in every overall figure (the headline's `p081` field); reading order is never judged on
  the 96 (its truth has no blocks, `ocr-scorers.md`).
- **OCR-5.** C-ocr's "within 0.6" is 1.59 (corrected 2026-10-30); no row uses the old figure.
- **OCR-6.** Region and tile losses on the 96 belong to note 03; this note offers whole-page reading except where
  note 03 rules a layout stage.
- **OCR-7.** No reading arm here alters the image; note 02 carries it.
- **OCR-8.** Note 01 carries the dewarp scope; the rows are all original-image readings.
- **OCR-9 (incomplete).** Rows with no public figure say so (`public` absent). Gemini 3.7 read all 895 (R-4: 879 read,
  16 content-filter refusals; +0.12, -0.66 to +0.93 against 3.8 on the 417 both read, a tie). Qwen3.6-35B-A3B's hosted
  row (OpenRouter fp8) carries no public figure; the FarmShare bf16 row carries it.
- **OCR-10, OCR-11.** Placement (note 05); not used here.
- **OCR-12.** The postcorrect verdict compares unlike builds (OpenRouter fp8 against Sherlock FP8); the "no stage"
  rule rests on the owner-material result only, and W46.ocr-postcorrect-paid was retired by the owner on 2026-11-04.
- **OCR-13.** The loop-fallback order was chosen on the 895 after scoring and reverses on the 96's 18 caps (second
  reader first 74.9, kraken first 63.8, retry first 57.4; `loop-rerun-20261021.md`) [M]. Owner call 7.4.
- **OCR-14.** 18 of the 96 truth images are still FineReader-processed PDF images (`11-measurement-audit.md`); 15
  others were replaced by camera JPEGs whose truth was drafted from the PDF image (`ocr-truth.md` card). No ABBYY
  text is an input. Condition on every 96 figure; no route moves by it that is measured.
- **OCR-15.** Gemini's public lead may include training exposure through CHURRO-DS; the Gemini rows carry it, and
  the CHURRO overlap check by image hash (C-ocr §5) is item 8.
- **OCR-16.** The bench's ranking table now carries Gemini 3.7 and the FarmShare runs (panel-data.json `headline`);
  part 5's cascades still cover only the 29 routes they were fitted on (`ArchiveOCRBench/README.md`).
- **R-4.** Two scorers give Gemini 3.7 77.2 (`gemini37-public.md`) and 76.87 strict (`ocr-scorers.json`) on the 895;
  the rows use `ocr-scorers.json` throughout so one scorer serves every route. Its cost is an estimate at 3.8's list.
- **R-5, R-6.** The bench baseline "qwen3.6-27b" is the hosted local-panel reading (95.38 answered), not FarmShare's
  run; a FarmShare route's 96 and 895 rows are different runs (fp8 against BF16 KV cache, 32 against 16 sequences);
  fp8 against bf16 KV moved Qwen3.6 27B by 0.28 on the 96. Carried as a caveat on each cluster row.
- **R-13.** Xiaomi-OCR-0 reads 88.66 on the Mac against 88.67 on Sherlock and PaddleOCR-VL 1.6 88.78 against 88.87; that agreement is the basis for owner call 7.5. The Mac seconds were taken by an engine session at
  background priority (LAY-3), so no Mac-seconds figure decides a route here; time is shown, not ranked.
- **P5-1.** The Mac card's truth and coverage were corrected (W46.mac-card-provenance, done): Mac rows claim no
  public figure, and Granite-Docling has none anywhere, so it has no row.
- **P7-3 and the 27.2 pairing rule.** Every Vision figure here is 27.2: on the 96 NES 81.4 to 83.1, +1.7 (-0.3 to
  +4.0); on the public 37.5 to 39.3. Vision answers 305 of 320 public pages (empty on 15 of 80 L7 pages that it read on
  26.6). A comparison that pairs a route with a 26.6 Vision text (`enh-dewarp.md`, `enh-ocr-input.md`,
  `ocr-postcorrect.md`, `ent-robust.md`, the segmentation text cache) is not used for a reading figure.
- **P7-6, P8-6.** The on-device model's public draw is 100 pages of L5-L8 of the 440, where Vision is cached; its
  handwriting +5.9 (-3.8 to +15.8, 13 pages it chose by finishing) and answered-page AUCs are post hoc; the image is
  seen at a fixed size from 768 px up, with a 512 px arm unmeasured; its bench pairing with Vision is now 27.2. None
  of this changes "not a reader".
- **P8-2.** On 27.2 Vision varies run to run on a few handwritten pages (p048, p050, p053; up to 3.7 NES a page,
  under 0.1 on the 96's mean). On the 15 empty L7 pages every word another route reads is "suspect", because Vision is
  the second reader. Rule: a page Vision returns empty for is a Vision failure, never a blank page.
- **P8-3 (and P9-1).** The 96 were drawn through a 20-word Vision (26.6) filter: 19 pages replaced, 4 of them tagged
  Handwritten, 10 with no kind tag (`ocr-truth.md`). So Vision's failure rate, every suspect rate, and every cascade or
  disagreement figure that uses Vision as the second reader are measured only on pages Vision could read. The
  Vision-as-first-reader and Vision-word-count trigger calls (7.1, 7.2) carry that condition. Vision's own failure rate has since been
  measured without the filter: under 20 words on 1 of 181 owner pages of text drawn one per document, nothing on
  none (W46.ocr-vision-unfiltered, `ocr-vision-unfiltered.md`).
- **P8-5.** The hands pair kraken-on-blla against Vision is +7.91 (-0.50 to +17.21) on the 27.2 text, a tie; the
  regeneration is recorded in the report.
- **P2-3 (the class: regenerated tables outlive their conclusions).** This note reads figures only from tables
  regenerated after the 2026-11-04 swap and their current prose, never an older figure in a commit body or DONE
  entry. Two stale figures found in the prototype's inputs are items 1 and 2.
- **P6-2.** The hands owner tables now score 16 handwritten and 2 mixed pages, the agreement-only letters out
  (W46.hands-owner-pages, done; `ocr-ppocrv6-hands.md` "The owner's 18").
- **P11-4.** Vision's time was not like for like: 0.21 s a page was the kind classifier's Vision step
  (`kind-classifier.md`), 1.3 s the mixed-route batch wall with launch; the Mac VLM seconds left model load out.
  Done (item 4, `ocr-time-like-for-like.md`, 2026-11-11): every Mac row's time is now one run's median on the same 16
  owner pages, load apart. Vision 0.19 s a page, Xiaomi-OCR-0 7.6, PaddleOCR-VL 1.6 3.7, LightOnOCR-3 4B 23.5,
  Qwen3-VL 8B 35.1, the on-device model 4.0, kraken PP-OCRv6 on blla 13.3; Qwen3.5 9B (33.7) is its own earlier
  reading of those pages, its weights since removed from the model cache. The readers timed again agree with their
  earlier walls page by page (0.95 to 1.01 of them), so the older Mac seconds were not slowed by background priority.
  Cloud rows take the median wall a call on the same 16 pages from the scoring runs' logs, at 2 to 6 calls in flight.
  The 16 are not the 96's page mix, so a row's time compares with the other rows, not with a 96-page median.
- **Mixed pages (`mixed-route-bands.md`).** Reading handwriting on typed pages costs nothing measurable in typed
  accuracy on typed pages (LightOnOCR-3 4B +1.8, -2.2 to +5.9, against Vision on 78 pages; 14 pages more than 2
  points worse) and is unmeasured on mixed pages (2 pages, -12.1, -20.7 to -3.6); timed like for like, it takes
  about 140 times Vision's time on the 9 typed and printed pages of the timing set (25.5 s against 0.17 s, medians;
  `ocr-time-like-for-like.md`). The setting is note 10's (W46.mixed-route-setting).

## 6. What would change the rule

- A Mac reader of 27B class measured on a 32 GB or 64 GB Mac (NES on the 96 within the tie rule of Qwen3.6 27B fp8's
  95.31 on FarmShare, with peak memory) adds a 32 or 64 GB pick; until then those tiers pick from the 16 GB rows.
- A paired matrix between every pair of routes the solver compares replaced the single-baseline pairing
  (W46.ocr-pair-matrix, W46.pair-matrix-cover), and section 9's picks were re-decided from it (W46.pairs-redecide;
  Infinity-Parser2-Pro's cluster hand pick is no longer pending: pooled L1-L3 settles it). A new reading row reruns
  `ocr_pair_matrix.py` and re-decides the picks it could change.
- Gemini 3.8 Flash read on L1-L4, L9, N2, N5 and N6 (W43.sweep) would let the hand and forms rules rank it on
  independent truth; a third-family route beating 95.81 on the 16 or 89.3 on L1-L3 by the tie rule changes the hands
  pick.
- A Vision reading of owner pages drawn without the 20-word filter, with truth, sets Vision's own failure rate and
  decides 7.1.
- The Gemini 3.8 Flash price doubling on 1 January 2027 (J-compute.md §3.1) moves it from $3.22 to a figure the
  price check reads then; at that price the cheaper tie partner wins wherever the rule finds a tie.
- A larger cascade test (the 96 hold 17-27 poor readings a reader, `ocr-logprob.md`) could make the disagreement
  trigger a default; today only escalation on failure holds on unseen pages.

## 7. Owner calls

**7.1 Apple Vision as the free first reader (decided: owner call 4).** Question: is Vision the reader the sheet picks for a user with no
download, key, plan or cluster, and for which kinds? Evidence: 83.61 answered on the 95 (51st of 53 in the headline by answered NES),
typewritten 92.18, printed 80.54, handwritten 60.58 strict; public 39.3 strict on 320 Latin pages, 305 answered; the
96 hold no page Vision reads as empty (P8-3); on 200 owner pages drawn without that filter it reads under 20 words on
1 of 181 pages of text (0.6%, 95% 0.1-3.1%; `ocr-vision-unfiltered.md`); on typed and printed
pages LightOnOCR-3 4B ties it (+1.8, -2.2 to +5.9). Options: (a) Vision is the free default for every kind;
(b) Vision for typed and printed pages only, with handwritten pages marked "needs a download or a key"; (c) Vision
only when no Mac reader fits, else a downloaded Mac reader. Recommendation: (b) for a user who declines a download,
(c) otherwise; in both, a page Vision returns empty for is flagged, not skipped.

**7.2 The cascade's default and its trigger: decided (owner call 5).** The cascade is a route like any other, with
no on/off default of its own; failure is the only trigger and the Vision word-count trigger stays opt-in (section
"Owner's calls"). Evidence as walked: escalation on failure beat one route on unseen pages by 0.8 to 2.8 points at
every budget up to $5 per 1,000 (`difficulty.md` §4); on the real corpus Qwen3.6 27B failed 13 of 2,000 pages, no kind
over 1.2%; the disagreement and kind triggers gain inconsistently on unseen pages; length against Vision ranks poor
readings at AUC 0.76-0.88 on the 96, conditional on the filter (P8-3).

**7.3 Which hands route per profile, given OCR-1 (decided: the recommendation).** Laptop: LightOnOCR-3 4B 8-bit (hands16 89.91; its FarmShare twin
86.2 on L1-L3) against Qwen3-VL 8B 4-bit (89.24; its FarmShare twin 80.6 on L1-L3, 18 empty); no Mac-against-Mac pair.
Cheap or premium API: Gemini 3.8 Flash (95.81, drafter; no L1-L3 reading) against Gemini 3.7 on the gateway (95.05;
89.1 on L1-L3) for gateway users. Plan: Claude Sonnet 5.5 (92.50, drafter's family; no public reading). Cluster:
Infinity-Parser2-Pro (91.76; 89.3 on L1-L3) against Qwen3.5 27B (92.23; 85.0) and Qwen3.6 27B (86.0 on L1-L3); no
pair between them. Options: rank hands on hands16; on L1-L3 where read; or on both, L1-L3 deciding a disagreement.
Recommendation: L1-L3 decides where both exist, hands16 otherwise, every hands figure labelled; this gives
LightOnOCR-3 4B on the Mac, Gemini 3.8 Flash on an API (labelled "conditional on the truth"), Infinity-Parser2-Pro on a
cluster pending its pair.

**7.4 The loop-recovery fallback order (OCR-13; decided: the recommendation).** Options: (a) readers first as filed (kraken PP-OCRv6 on lines,
second reader, n-gram, stock PP-OCRv6; 50.3 pooled on 1,652 public caps, fitted after scoring); (b) second VLM reader
first, then kraken on Latin pages, then n-gram (the 96's 18 caps: 74.9 against 63.8); (c) on the Mac, n-gram or a
second reader (the three MLX loops: half size 87.5, second 83.3, n-gram 75.8, kraken 73.1; three pages). Never half
size on the cluster. Recommendation: (b) where a second reader is installed, (a)'s kraken step where none is; the
order is not settled by 18 pages, so it is a setting the solver fills, not a measured optimum.

**7.5 Which public-strata figures the sheet may show for which routes (decided: the recommendation).** Proposed: a row shows the strata its own
run read, with answered/n; Gemini 3.8 Flash and Qwen3-VL 235B the 440's seven strata; Vision L5-L8 with 305 of 320;
Gemini 3.7 all fifteen; cluster rows all fifteen; kraken specialists their own strata with the source-overlap note; the
on-device model none. Question: may a Mac row show its cluster twin's public figures, labelled "same weights on a
cluster" (Xiaomi-OCR-0 and PaddleOCR-VL 1.6 agree within 0.1 on the 96, R-13; LightOnOCR-3 4B 89.15 Mac against 89.38
FarmShare at different precision)? Recommendation: yes for the same weights and precision (Xiaomi, PaddleOCR-VL),
labelled; no for LightOnOCR-3 4B (8-bit on the Mac) until its Mac build reads L1-L3.

**7.6 The Mac memory tiers and their picks at 16, 32 and 64 GB (decided: (a)).** Measured, on one 18 GB M3 Pro only: MLX peaks 2.74
(PaddleOCR-VL), 2.92 (Xiaomi), 6.45 (LightOnOCR), 7.48 (Qwen3.5 9B), 7.64 GB (Qwen3-VL 8B); whole-process 3.46 to 9.10
GB; Qwen3-VL 8B ran with memory pressure at "warn". With the solver's 5 GB headroom every one fits 16 GB [I]. No
27B-class reader has run on a Mac; the gap audit's 32 GB candidate (Qwen3.6 27B 4-bit) and 64 GB candidate (27B 8-bit)
have cluster and hosted figures only, and the lab has no 32 GB Mac (`10-gap-audit.md` open question 4). Options:
(a) 32 and 64 GB pick from the 16 GB rows until a Mac measurement exists; (b) the sheet offers the 27B at 32 GB with
the cluster figure, labelled unmeasured on a Mac. Recommendation: (a), with item 3 filed.

**7.7 Tie-breaking among free routes, and chained ties (decided: the first).** The design gives a tie to the cheaper route; among free
routes nothing breaks it, and ties judged pairwise can chain (Gemini 3.8 ties Qwen3.6 27B, which ties Qwen3.8 Flash).
Options: judge ties against the best feasible route only, then faster wins among equal cost; or allow chaining.
Recommendation: the first.

**Not measured, so not offered: the ChatGPT plan.** Codex answered "out of credits" on the first call and Sol was
dropped (`ocr-panel-cloud.md`); GPT-5.6 Luna was read through OpenRouter instead. No plan row exists; item 7.

## 8. Items to file

1. **`W46.figures-cascade-cost`** [XS · $0]. `build_figures.py` writes a cascade's cost as `usd / 96 * 1000`, but
   panel-data.json's `difficulty.cascades.frontier[].usd` is already dollars per 1,000 (`difficulty.md` "$ / 1,000";
   Gemini 3.1 Pro alone is 21.92 there, its $0.02192 a page), so every `figures.json` cascade cost is 1000/96 times
   too high (228.33 for 21.92) [M]. Done: the cost copied as is, the prototype rebuilt. Waits on nothing.
2. **`W46.figures-cross-run`** [XS · $0]. `build_figures.py` joins hand and public figures across runs: the
   `-farmshare`/`-sherlock` rows take the hosted run's `hands16` (qwen3.6-27b 92.61, qwen3.6-35b-a3b 88.83, qwen3.5-9b
   91.00), and hosted rows take the FarmShare run's public figure (qwen3.6-27b 63.3), against OCR-9 and R-6; its
   overall figures are strict on all 96 for most rows and the cluster reports' own scores for cluster rows, not the
   headline's answered NES. Done: the generator reads the rows of this note's sources, one run per figure, and a
   cluster row that joins the 96 run with the 895 run names both runs in a caveat (R-6); every cluster row with a
   public figure carries it. Waits on nothing.
3. **`W46.ocr-mac-27b`** [S · Mac-local, $0 · needs a 32 GB Mac or a borrowed one]: Qwen3.6 27B 4-bit (and 8-bit on
   64 GB) on the 96 with peak memory and seconds a page, both sets; done when the 32 and 64 GB rows exist. Waits on
   the hardware (gap audit open question 4); otherwise an owner question.
4. **`W46.ocr-time-like-for-like`** [XS · Mac-local, $0]: Vision and each Mac reader timed per page in one run outside
   an engine session, model load apart (P11-4, LAY-3); done when every Mac row's `time` is like for like. Shipped
   2026-11-11 (`ocr-time-like-for-like.md`; the engine session ran at utility priority, which a CPU check showed runs
   at full speed). Cloud
   seconds a page (12-settings-design §3.9) in the same item from the existing logs where they exist.
5. **`W46.ocr-pair-matrix`** [S · $0, offline]: paired bootstrap intervals for every pair of routes the solver can
   compare, on the 96 (answered and strict) and per stratum on the 895, from `ocr-pages.csv` and
   `ocr-scorers-pages.csv`; done when the table's `noise` points at it. Waits on nothing. Shipped 2026-11-11: `ocr-pair-matrix.md`.
6. **`W46.settings-routes-r8`** [XS]: the schema's `stages` and `trigger` fields for cascade rows, and `kinds` ids
   for the public strata, in `settings_routes.py`. Waits on the generator item.
7. **`W46.ocr-plan-chatgpt`** [S · plan route, no money]: the 96 through the app's Local Agent backend on the ChatGPT
   plan; done when a plan row exists or the route is ruled out. Owner question (the plan's credits).
8. **`W46.ocr-churro-overlap`** [XS · $0]: page-level image-hash overlap between CHURRO-DS's test pages and the 895
   (OCR-15, C-ocr test 5); done when the Gemini and Churro public rows carry the overlap count. Waits on nothing.
9. **`W46.ocr-vision-unfiltered`** [S · Mac-local, owner about 20 minutes]: a Vision failure rate on owner pages drawn
   without the 20-word filter (the 19 replaced pages plus a salted draw outside the 96), counted as empty or under 20
   words against the owner's yes or no "this page has text"; no truth transcription needed. Done when 7.1 has a
   measured failure rate. Waits on nothing.
10. **`W46.ocr-rows-omitted`** [XS · $0]: rows for the cheap hosted routes listed under "Not in the table"
    (`gemma4-31b`, `qwen3.5-9b`, `gemma4-26b-a4b`, `mistral-small-24b`), a check that no dominated route leads on a
    public stratum, and a rerun of `qwen3.5-27b` on the 96 that answers the pages its transport errors lost (its list
    price $1.80 per 1,000); done when each has a row or a stated reason. Waits on the generator item. Done
    2026-11-11: five rows (the four and `churro-3b-farmshare`), the strata check under "Not in the table", the
    rerun deferred as paid (`paid-runs-deferred.md`).
11. **Gaps already known, not refiled:** Gemini 3.8 Flash and the other hosted rows on the 455 (W43.sweep, held);
    Infinity-Parser2-Pro's licence and kit status (C-ocr §8). Since 2026-11-17 a licence alone excludes nothing: a
    research or non-commercial model may be an optional download with its licence shown (`00-plan.md`).

## 9. Profile test expectations

The solver's expected picks from the rows, by the rule above (answered NES when a fallback is on, strict when off;
ties against the best feasible route only, cheaper then faster, as 7.7 recommends). Figures from section 4's rows.
Re-decided from the pair matrix under the owner's floor-only rule (W46.pairs-redecide, 2026-11-11): each pick names
its entry in `ocr-pair-matrix.json` as `set/group/score`, the gap a minus b with its 95% interval and n. A pair of Mac
routes has the floor 0.00, so any paired gap separates two of them; on the 895 a pick takes the stratum's leader.

**1. Laptop, open weights (16, 32 and 64 GB the same until item 3).**
- Typewritten, no download: `apple-vision` (92.18 strict, the free default of owner call 4). With downloads:
  `paddleocr-vl1.6-bf16` (93.69), the leader; `qwen3.5-9b-mlx4` (93.32) trails it by −0.37 [−6.12, +5.08] (n 50,
  owner96/typewritten/strict), over the Mac floor 0.00, so not a tie.
- Printed: `qwen3.5-9b-mlx4` (92.78): over Qwen3-VL 8B +1.09 [−5.39, +9.36] and over LightOnOCR-3 4B +5.00 [−0.20,
  +10.88] (n 27, owner96/printed/strict), Mac pairs, no tie.
- Handwritten: `lightonocr-3-4b-mlx8` (hands16 89.91), the leader: over Qwen3-VL 8B +0.67 [−1.89, +2.92] and over
  Qwen3.5 9B +1.85 [−0.00, +3.58] (n 16, owner96/hands16/strict), Mac pairs with the floor 0.00 (not the 0.60 hand
  floor, which is a hosted floor), so no tie.
- All kinds, cascade off (strict): `qwen3.5-9b-mlx4` (91.95), over Qwen3-VL 8B +2.27 [−1.98, +6.97] and PaddleOCR-VL
  +3.02 [−0.94, +7.24] (n 95, owner96/all/strict). Loop fallback on (answered): `qwen3-vl-8b-mlx4` (93.62), Qwen3.5 9B
  minus it −0.59 [−2.34, +0.88] (n 90, owner96/all/answered), a Mac pair, no tie, so the speeds (40.8 against 37.6 s a
  page, P11-4) do not enter.
- Free cascade: `casc-free-fail` (split half 92.67 against the single route's 91.89) once a Mac escalation stage exists
  (no per-page scores: pair not measured, floor alone).
- Forms, newspapers, non-Latin, early modern hands: no Mac row has its own public figure; under 7.5's recommendation
  `xiaomi-ocr-0-bf16` shows Xiaomi-OCR-0's L4 52.2, L9 95.17, N2 27.06, N6 78.67. Early modern hands on Latin
  scripts: the kraken specialists where installed (L6 72.64 German handwriting; L5 65.59 CATMuS; L7 46.42 TRIDIS).
- Never: `apple-fm-27`.

**2. Cheap API (OpenRouter key).**
- All kinds: best feasible `gemini3.1-pro` 96.85 ($21.92); `gemini3.8-flash` 96.47 minus it −0.38 [−2.17, +0.90]
  (n 93, owner96/all/answered), under the 0.49 floor, a tie, cheaper, so `gemini3.8-flash` ($3.22; batch $1.61).
- Handwritten: `gemini3.8-flash` (hands16 95.81), the leader: over Gemini 3.1 Pro +1.84 [+0.04, +4.25] (n 16,
  owner96/hands16/strict), over the 0.60 floor; labelled conditional (OCR-1).
- Without Gemini (open weights only): `qwen3.6-27b` 95.38 ($1.94) is best; `qwen3.8-flash` 95.11 ($0.60) minus it
  −0.08 [−1.62, +1.64] (n 91, owner96/all/answered), a tie, so `qwen3.8-flash`; its 3 refusals go to a fallback. With
  no fallback (strict) it is −2.27 [−6.77, +1.90] (n 95), no tie; but `qwen3-vl-235b` ties the 27B on strict, −0.37
  [−2.16, +1.92] (n 95, owner96/all/strict, under the 0.49 floor), and is cheaper ($1.22), so `qwen3-vl-235b`
  (found by W46.settings-solver's test). Handwritten: `qwen3.6-27b` (hands16
  92.61); `mistral-large4` ties it, −0.42 [−1.45, +0.68] (n 16, owner96/hands16/strict), but costs more ($2.69), and
  every other OpenRouter route trails beyond the 0.60 floor (Qwen3-VL 235B −1.02, Qwen3.8 Flash −1.36). `qwen3.5-27b`
  (95.86 answered on 82 pages) has no row until its rerun (paid, deferred to W43.sweep); it would then be the best
  feasible here.
- A price cap from $0.25 to under $0.60 per 1,000: `qwen3.5-9b` 93.38 ($0.25). Where the cap reaches $0.38 the best
  feasible is `gemma4-31b` 93.76; `qwen3.5-9b` minus it +0.41 [−1.71, +2.66] (n 88, owner96/all/answered), under the
  0.49 floor, so the cheaper `qwen3.5-9b` still. Under $0.38 `mistral-small-24b` ($0.32) trails `qwen3.5-9b` by
  −2.65 [−5.02, −0.48] (n 89).
- Early modern and non-Latin strata: `gemini3.8-flash` on the 440's strata (L5 63.17, L6 72.87, L7 57.95, N1 74.66,
  N3 88.79, N4 46.14); forms, newspapers, N2, N5, N6: no OpenRouter row has a figure.

**3. Premium APIs or plans.**
- Gemini key: as profile 2. Gateway users: `gemini3.7-flash-gw` (96.76; the only hosted route on all fifteen strata:
  L4 83.22, L9 96.81, N2 24.01).
- Claude plan only: `claude-sonnet5.5` (96.48, no money, window share); handwritten 92.50 labelled as a drafter family.
- ChatGPT plan only: no measured row; the sheet says so.

**4. A cluster.**
- All kinds: `qwen3.5-27b-farmshare` 95.38 is best; `qwen3.6-27b-farmshare` 95.31 minus it −0.07 [−0.71, +0.47]
  (n 95, owner96/all/answered), under the 0.49 floor, a tie; free, so the faster, `qwen3.6-27b-farmshare` (1,054.7
  pages an hour against 1,025.6; 895 63.26 strict). Not tied: `qwen3.5-9b-sherlock` (95.13), −0.76 [−1.53, −0.09]
  against the leader and −0.66 [−1.36, −0.04] against `qwen3.6-27b-farmshare` (n 93; strict −2.25 and −2.19, n 95),
  so the earlier "fastest of the free ties" pick goes; `qwen3.6-35b-a3b-farmshare` (94.56), −0.83 [−2.00, +0.06]
  (n 95). Strict gives the same pick (every 27B page answered).
- Handwritten: `infinity-parser2-pro-sherlock` (L1-L3 89.3; two GPUs), the leader of pooled L1-L3 over every other
  cluster route, +3.09 [+1.57, +4.64] against LightOnOCR-3 4B to +13.37 against PaddleOCR-VL (n 240,
  public895/L1-L3/strict; +3.32 [+1.99, +4.83] against `qwen3.6-27b-farmshare`). On hands16 it ties
  `qwen3.5-27b-farmshare`, −0.47 [−1.87, +0.89] (n 16, floor 0.60), and on the pre-sheet `handwritten` group trails
  `qwen3.6-27b-farmshare` by −1.04 [−3.02, +0.71]; the independent truth of the 240 decides (kind rule, OCR-1).
- Newspapers: `qwen3.5-27b-farmshare` (L9 95.84), the leader of public895/L9/strict; Xiaomi-OCR-0 −0.66 [−3.01, +1.50]
  and `qwen3.6-27b-farmshare` −2.28 [−7.75, +2.22] behind (n 15). Descriptive: 15 pages of about one collection
  (P13-7), so the card says so.
- Forms: `qwen3.5-27b-farmshare` (L4 69.98), the leader of public895/L4/strict; `qwen3.6-27b-farmshare` −0.69
  [−6.71, +5.37], `qwen3.6-35b-a3b-farmshare` −2.87 [−8.33, +2.76], Infinity −3.07 [−7.90, +1.83] (n 80). Their
  intervals hold 0, which on the 895 makes no tie for a pick (§3), so the leader stands.
- N6: `xiaomi-ocr-0-sherlock` 78.67, Infinity −0.41 [−4.34, +3.22] (n 40, public895/N6/strict); Xiaomi is also the
  faster (9,322.5 pages an hour against 1,206.0 on two GPUs), so the pick holds under any floor.
- Early modern hands and non-Latin strata of the 440 (L5-L8, N1, N3, N4): `churro-3b-farmshare` (L6 69.45, N3 84.70),
  the leader on each of the seven strata; its smallest leads are L8 +2.95 [−0.03, +4.94] over Infinity and N4 +12.07
  [−0.55, +24.12] over `qwen3.6-27b-farmshare` (n 80, 40, public895/<stratum>/strict). Labelled with OCR-15 (trained on
  CHURRO-DS) and its research-only licence; since 2026-11-17 a research licence no longer excludes a model, which is offered
  with the licence shown (`00-plan.md`; CHURRO's remaining strata in W46.ocr-family-coverage).

**5. Any of these plus a coding agent.** The kit's same-hand kraken PP-OCRv6 fine-tune is an after-training row (note
12): +2.6 (+1.7 to +3.4) at 160 lines on MPS on one public hand, worse on 3 of 4 owner Shils pages; corrected lines in the
prompt gain nothing (Qwen3.6 27B -1.34 and -0.68; Gemini 3.7 +0.25 and -0.46, all ties). The solver picks as for the
profile beneath it until a user's own held-out check passes.


## Owner's calls (2026-11-06)

From `14-owner-calls.md`; section 3 is amended where a call changes it.

- **Call 4, the free default's reader per kind (7.1).** Typed and printed pages are read at once with Apple Vision.
  Handwritten pages: on a 16 GB Mac the sheet proposes LightOnOCR-3 4B 8-bit as a download; a user who declines, or a
  smaller Mac, gets them flagged "needs a download or a key" rather than read at about 60. A page Vision returns empty
  for is flagged, never skipped, on every profile. Section 3's kind rules carry this.
- **Call 5, the failure cascade (7.2; note 10 call 2).** A route like any other: each measured cascade is a row on the
  reading chart with its own figures (the split half in `value`), and the solver picks it when it beats the single
  routes within the user's limits. No separate on/off default; failure is the only trigger; the Vision word-count
  trigger stays opt-in. This note owns the cascade rows; note 10 points here. The earlier recommendation "(b) on
  whenever a second route exists" is superseded.
- **Section 2's reading picks (7.3 to 7.7; owner may veto).** Hands routes ranked on the public L1-L3 where both
  figures exist, hands16 otherwise, every hands figure labelled (OCR-1): LightOnOCR-3 4B on the Mac, Gemini 3.8 Flash
  on an API labelled "conditional on the truth", Infinity-Parser2-Pro on a cluster pending its pair. Loop fallback: a
  second VLM reader first where installed, kraken PP-OCRv6 on Latin lines where none, never a half-size retry on the
  cluster; a solver setting, not a measured optimum (18 pages). Public strata shown per row for the run that read
  them; a Mac row may show its cluster twin's figures only for the same weights and precision. 32 and 64 GB Macs pick
  from the 16 GB rows until a Mac measurement of a 27B-class reader exists (item 3). Ties judged against the best
  feasible route only, faster wins among equal cost; no chaining. The ChatGPT plan has no OCR row (item 7).
- **Note 03's layout pick, as it bears here.** PP-DocLayoutV3 regions on newspapers for every reader; never on
  handwriting or registers; the cluster "regions first for small readers" is a kind rule on this note's cluster rows,
  which the every-reader newspaper rule in section 3 covers.

Files read: `execution-plans/processing-review/00-plan.md` (lines 1-105); `13-stage-rules/00-index.md` (worktree
suite-wt-20261106-205546-44529); `settings-design/figures.json`, `build_figures.py`; `12-settings-design.md` (§3.3,
§3.9, §5); `C-ocr.md` §5, §6, §8; `10-gap-audit.md` stage 4 rows; `J-compute.md` §6; `11-measurement-audit.md`
OCR-1 to OCR-16; `measure-reviews/2026-10-31.md` (R-3 to R-7, R-13), `2026-10-31-2.md` (P2-3), `2026-11-02.md` (P5-1),
`2026-11-03.md` (P6-2), `2026-11-04.md` (P7-3, P7-6), `2026-11-04-2.md` (P8-2 to P8-6), `2026-11-05.md` (pass 9 table,
P9-1), `2026-11-05-2.md` (P10-10), `2026-11-05-3.md` (P11-4, P11-8); `ArchiveOCRBench/README.md` part 1,
`ArchiveOCRBench/data/panel-data.json` (headline, charts, routes, farmshare, difficulty, loops), `ArchiveOCRBench/difficulty.md`
§4-§6 and the routing rule; in `ArchiveProcessor/segbench-results/`: `ocr-scorers.md` and `.json`,
`ocr-rerun-noise.md`, `ocr-panel-cloud.md`, `ocr-mac-local.md`, `ocr-mac-local-hw.md`, `ocr-hands-rescore.md` and
`.json`, `ocr-ppocrv6-hands.md` and `.json`, `ocr-ppocrv6-hands-qwen.md`, `ocr-ppocrv6-hands-paid.md`,
`ocr-postcorrect.md`, `ocr-logprob.md`, `ocr-truth-bias-score.md`, `ocr-truth.md`, `gemini37-public.md`,
`gemini37-vs-38.md`, `vision-27-reread.md`, `r1-foundation.md`, `r6-spot.md`, `mixed-route-bands.md`,
`farmshare/truth96-20261020.md`, `bench-corpus/open-sweep-20261019.md`, `bench-corpus/loop-rerun-20261021.md`,
`bench-corpus/routes.csv`; `SUITE_TODO.md` and `SUITE_TODO_DONE.md` (W41.app-ocr-cascade and the W46 items named);
`ArchiveProcessor/CLAUDE.md` (cascade); for the 2026-11-06 corrections, `ArchiveOCRBench/build.py` (failure classes),
`layout-photo.md`, `measure-reviews/2026-11-01.md` §1, `13-stage-rules/14-owner-calls.md`. Not read: `ocr-panel-local.md` beyond its rows quoted elsewhere, `specialists.md`.
