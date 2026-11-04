# W46.r1-foundation — the macOS 27 on-device model as a free first reader

Reproduce: `ArchiveProcessor/scripts/segbench/fm_foundation.py` (its header has every step and every setting fixed before the first answer). Model: Apple's on-device `SystemLanguageModel` on macOS 27.2, on the M3 Pro with 18 GB; Private Cloud Compute never called. No money, no network. Page text stays in the cache.

## Findings

- **Not a first reader.** On the owner's 96 it scores 42.4 NES against Apple Vision's 81.4 on the same images (-39.0 points, interval -47.0 to -31.0). A third of the pages (33 of 96) run into a repetition loop and reach the 4,096-token cap; cutting each loop where it starts recovers only 4 points (46.4). Where it finishes a page it still trails Vision on typed (-19.8) and printed (-28.1) pages.
- **Handwriting is the one lead, and it is a tie.** On the 13 handwritten pages it finished it reads 67.5 against Vision's 59.4 (+8.1, interval -1.1 to +17.7). Those 13 are chosen by the model itself finishing, so this is a lead for a test with a loop stop, not a result.
- **The image is seen at a fixed small size.** 131 image tokens for any page from 768 px to 2,400 px on the long side (147-163 for other aspect ratios); sending more pixels buys nothing, and the resolution arm is moot. A page takes 9.5 s at the median, 80 s when it loops.
- **Disagreement flags its own bad pages, not Vision's.** Its disagreement with Vision picks out its own pages under 70 NES at AUC 0.92 (answered pages); Vision's own pages under 70 only at 0.84 and under 90 at 0.77 on the pages it answered, and at 0.63 and 0.55 over all 96, because its loops (zero agreement) fall mostly on pages Vision reads well. As a free routing voter beside Vision it is weak, and its loops make it noisy.
- **No text-only segmentation voter.** On Deaver, Gemini 3.7's k3-t prompt word for word gives replies that copy the pasted schema's wrapper (139 of 149 unparsable); with guided generation into the same fields, 132 parse but score 33.3% of pages in an exact document against Gemini 3.7's 93.6% (-60.3 points), 49 false splits: no better than the failed windows' 0.5 votes.
- **Guardrails.** The stock guardrail refused an owner page on the pilot; permissiveContentTransformations was used throughout, and still refused 3 of 149 segmentation windows.
- **The 100 of the 895 are PENDING** (the run was still reading when this was written; the table shows what is in).

## OCR

| set | read / n | NES % (failures empty) | NES % answered | NES %, loops cut (post hoc) | Apple Vision NES % (27.2) | difference from Vision, points (95% interval) | failures |
|---|---:|---:|---:|---:|---:|---:|---|
| The owner's 96 | 63/96 of 96 | 42.4 | 64.5 | 46.8 | 83.1 | -40.7 (-49.0 to -32.5) | length 33 |
| 100 Latin pages of the 440 reference set (25 from each of L5-L8) | 3/16 of 100 | 0.9 | 4.8 | 3.6 | 52.4 | -51.5 (-61.8 to -40.2) | length 13 |

### The owner's 96: by group

The columns on the pages it read, and their intervals, were added after the 96 were read (post hoc); no interval under ten pages.

| group | n | read | on-device NES % | Vision NES % | on-device NES %, pages it read | Vision NES %, the same pages | difference on those pages (95% interval) |
|---|---:|---:|---:|---:|---:|---:|---:|
| handwritten | 16 | 13 | 54.8 | 60.6 | 67.5 | 61.5 | +5.9 (-3.8 to +15.8) |
| mixed | 2 | 2 | 49.5 | 70.8 | 49.5 | 70.8 | – |
| printed | 28 | 15 | 28.0 | 80.5 | 52.2 | 77.6 | -25.4 (-40.6 to -11.4) |
| typewritten | 50 | 33 | 46.1 | 92.2 | 69.9 | 90.3 | -20.4 (-27.9 to -13.5) |

### 100 Latin pages of the 440 reference set (25 from each of L5-L8): by group

The columns on the pages it read, and their intervals, were added after the 96 were read (post hoc); no interval under ten pages.

| group | n | read | on-device NES % | Vision NES % | on-device NES %, pages it read | Vision NES %, the same pages | difference on those pages (95% interval) |
|---|---:|---:|---:|---:|---:|---:|---:|
| L5 | 16 | 3 | 0.9 | 52.4 | 4.8 | 65.7 | – |

## Speed and tokens

| set | seconds a page, median / mean / 90th / max | total minutes | input tokens (image + prompt), median (min-max) | image tokens (tokenCount) | output tokens, median / max |
|---|---:|---:|---:|---:|---:|
| The owner's 96 | 9.5 / 32.1 / 80.5 / 90.8 | 51 | 244 (244-276) | 131 on 53, 147 on 41, 163 on 2 | 369 / 4102 |
| 100 Latin pages of the 440 reference set (25 from each of L5-L8) | 90.3 / 333.8 / 110.9 / 4240.2 | 89 | 244 (244-260) | 131 on 11, 147 on 5 | 4102 / 4102 |

Image tokens against the size sent (owner pages of three shapes, `tokenCount(for: Attachment)` and the session's own input count for a five-token reply; the long side is downsampled to at most the size named, never enlarged):

| page | long side px | sent | tokenCount | session input tokens |
|---|---:|---|---:|---:|
| p002 | 256 | 191x256 | 67 | 125 |
| p002 | 512 | 382x512 | 195 | 253 |
| p002 | 768 | 573x768 | 131 | 189 |
| p002 | 1024 | 765x1024 | 131 | 189 |
| p002 | 1536 | 1148x1536 | 131 | 189 |
| p002 | 2400 | 1793x2400 | 131 | 189 |
| p002 | 4000 | 1793x2400 | 131 | 189 |

## Disagreement with Apple Vision as a routing signal

Risk = 1 − NES(on-device text, Vision text), 0 agreement when either failed. AUC 0.5 is chance. On all pages a failure is the worst risk by construction, so "this model failed" is 1.00 by definition; the answered-only columns drop the failures and are the honest test of the signal; they were added after the 96 were read (post hoc).

| set | label | positives, all | AUC, all pages | positives, answered | AUC, answered pages |
|---|---|---:|---:|---:|---:|
| 96 | this model NES < 70 | 65 | 0.97 | 32 | 0.93 |
| 96 | this model NES < 90 | 85 | 1.00 | 52 | 1.00 |
| 96 | this model failed | 33 | 1.00 | 0 | – |
| 96 | Apple Vision NES < 70 | 21 | 0.59 | 16 | 0.82 |
| 96 | Apple Vision NES < 90 | 37 | 0.51 | 29 | 0.75 |
| 100 | this model NES < 70 | 16 | – | 3 | – |
| 100 | this model NES < 90 | 16 | – | 3 | – |
| 100 | this model failed | 13 | 1.00 | 0 | – |
| 100 | Apple Vision NES < 70 | 13 | 0.38 | 3 | – |
| 100 | Apple Vision NES < 90 | 16 | – | 3 | – |

## Text-only segmentation on Deaver

149 K = 3 text-only windows. The plain arm sends Gemini 3.7's k3-t prompt word for word, its JSON schema pasted at the end; the guided arm drops the pasted schema and uses the framework's guided generation into the same fields and enums. A failed or unparsed window votes 0.5.

- on-device k3-t: 139 failed (unparsed 139); 5.9 s a window (median), 15 min in all; input 3332 tokens a window (max 3670).
- on-device k3-t guided: 17 failed (refusal 3, unparsed 14); 6.6 s a window (median), 16 min in all; input 3375 tokens a window (max 3717).

| route | pages in an exact document % | boundary F1 % | false splits | false merges |
|---|---:|---:|---:|---:|
| on-device k3-t | 34.0 | 75.7 | 49 | 3 |
| on-device k3-t guided | 33.3 | 72.1 | 49 | 9 |
| Gemini 3.7 k3-t | 93.6 | 97.6 | 2 | 2 |
| Gemini 3.7 k3-it | 92.2 | 98.2 | 2 | 1 |

Paired, pages in an exact document, bootstrap over truth documents:

- on-device k3-t − Gemini 3.7 k3-t: -59.6 points (-69.9 to -47.4), 141 pages
- on-device k3-t − Gemini 3.7 k3-it: -58.2 points (-68.9 to -46.3), 141 pages
- on-device k3-t guided − Gemini 3.7 k3-t: -60.3 points (-71.0 to -47.2), 141 pages
- on-device k3-t guided − Gemini 3.7 k3-it: -58.9 points (-69.6 to -46.8), 141 pages

## Measurement card

- **Truth.** The owner's 96 pages (99 less the three agreement-only letters), truth drafted by Claude Opus 5.5 and Gemini 3.8 Flash and adjudicated by the owner where they differed (`ocr-truth.md`), corrected on 2026-10-29 (W46.truth-edits). Words the two drafters wrote alike were not adjudicated; since then the owner has checked samples of them blind: 59 places on 20 pages where Qwen3.6-27B differs (answered 2026-10-21, `ocr-truth-bias-score.md`: 4 truth errors, the bias not material) and every place where Qwen3.6-27B or LightOnOCR-3 4B differs on the 16 hand pages, with 19 typed controls (answered 2026-10-31, `ocr-hands-rescore.md`: 12 corrections, 10 places unresolved). Agreed words that no third-family reader disputes stay unchecked, so a drafter-family route can still gain where the truth shares its mistake. The 100 Latin pages carry their public sets' own transcriptions (corpus/README), scored at each page's stratum. Deaver's segmentation truth is the bench's development-box truth (data.py). No drafter is scored here.
- **Selection.** The 96 are every accuracy page; the 100 are a seeded draw, 25 from each of the 440 reference set's four Latin-script strata (L5-L8, where Vision's readings are cached; not the 895's nine strata), made before any reading (SEED in the script); Deaver is the development box seg_window_gateway already read at K = 3. None chosen by a route's reading or by ABBYY text.
- **Comparison.** Apple Vision on the same images (the shipped free reader), its macOS 27.2 re-read (W46.vision-27-reread), so both readers ran on the same OS build; for segmentation, Gemini 3.7 Flash's k3-t and k3-it on the same windows and prompt. The on-device model gets a plain transcription prompt where the panel's routes get the KIND/TEXT prompt; that difference is the route as an app would call it, and is named here.
- **Noise.** n = 96 and 100 pages, paired bootstrap intervals on the page differences. The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. Greedy decoding on one Mac; one reading of each page. Segmentation n = one box (149 pages), intervals over its truth documents.
- **Scope.** One Mac, one OS build, one prompt; the 100 are Latin script only, from L5-L8 of the 440; text-only segmentation on one box, not the three. The loops-cut score, the answered-page groups and intervals and the answered-page AUCs were added after the 96 were read. Apple may change the model with an OS update, so these figures are for macOS 27.2 (26B123), both readers.

