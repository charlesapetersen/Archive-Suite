# W46.r1-foundation — the macOS 27 on-device model as a free first reader

Reproduce: `ArchiveProcessor/scripts/segbench/fm_foundation.py` (its header has every step and every setting fixed before the first answer). Model: Apple's on-device `SystemLanguageModel` on macOS 27.2, on the M3 Pro with 18 GB; Private Cloud Compute never called. No money, no network. Page text stays in the cache.

## Findings

- **Not a first reader.** On the owner's 96 it scores 42.4 NES against Apple Vision's 83.1 on the same images, both read on macOS 27.2 (-40.7 points, interval -49.0 to -32.5). A third of the pages (33 of 96) run into a repetition loop and reach the 4,096-token cap; cutting each of those loops where it starts (post hoc) recovers 4.4 points (46.8). Where it finishes a page it still trails Vision on typed (-20.4, -27.9 to -13.5) and printed (-25.4, -40.6 to -11.4) pages.
- **Handwriting is the one lead, and it is a tie.** On the 13 handwritten pages it finished it reads 67.5 against Vision's 61.5 (+5.9, interval -3.8 to +15.8). Those 13 are chosen by the model itself finishing, and the answered-page comparison was added after the 96 were read, so this is a lead for a test with a loop stop, not a result.
- **Worse on the 100 Latin pages (the 440 reference set's L5-L8, medieval and early-modern hands).** 10.6 NES against Vision's 40.9 (-30.2, -35.7 to -24.9); 55 of 100 loop to the cap. Where it finished, it trails on L8 (53.9 against 74.4, -20.5, -28.5 to -13.4) and ties on L7, where both readers fail (9.7 against 13.9, -4.2, -8.8 to +0.4); L5 and L6 have too few finished pages (4 and 7) for an interval.
- **The image is seen at a fixed small size.** On three page shapes, the token count stops growing at 768 px on the long side: 131 tokens for a 3:4 portrait and a 4:3 landscape page, 163 for a tall 1:3 page, the same at 2,400 px (512 px gives 195 and 131, 256 px 67 and 35). Sending more than 768 px buys nothing, so a resolution arm above that is moot. A page takes 9.5 s at the median on the 96 (mean 32 s) and about 80 s when it loops; on the 100, 77 s at the median (one page, read in session 1, took 4,240 s, cause not recorded; it is why the mean there is 93 s).
- **Disagreement flags its own bad pages, and Vision's only weakly.** On the 96 its disagreement with Vision picks out its own pages under 70 NES at AUC 0.93 (answered pages, post hoc); Vision's own pages under 70 at 0.82 and under 90 at 0.75 on those answered pages, and at 0.59 and 0.51 over all 96, because its loops (zero agreement) fall mostly on pages Vision reads well. As a free routing voter beside Vision it is weak, and its loops make it noisy.
- **No text-only segmentation voter.** On Deaver, Gemini 3.7's k3-t prompt word for word gives replies that copy the pasted schema's wrapper (139 of 149 unparsable); with guided generation into the same fields, 132 parse but score 33.3% of pages in an exact document against Gemini 3.7's 93.6% (-60.3 points), 49 false splits: no better than the failed windows' 0.5 votes.
- **Guardrails.** The stock guardrail refused an owner page on the pilot; permissiveContentTransformations was used throughout, and still refused 3 of 149 segmentation windows.

## OCR

| set | read / n | NES % (failures empty) | NES % answered | NES %, loops cut (post hoc) | Apple Vision NES % (27.2) | difference from Vision, points (95% interval) | failures |
|---|---:|---:|---:|---:|---:|---:|---|
| The owner's 96 | 63/96 of 96 | 42.4 | 64.5 | 46.8 | 83.1 | -40.7 (-49.0 to -32.5) | length 33 |
| 100 Latin pages of the 440 reference set (25 from each of L5-L8) | 45/100 of 100 | 10.6 | 23.6 | 14.9 | 40.9 | -30.2 (-35.7 to -24.9) | length 55 |

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
| L5 | 25 | 4 | 0.9 | 47.5 | 5.4 | 54.6 | – |
| L6 | 25 | 7 | 3.7 | 27.0 | 13.3 | 27.8 | – |
| L7 | 25 | 20 | 7.7 | 13.9 | 9.7 | 13.9 | -4.2 (-8.8 to +0.4) |
| L8 | 25 | 14 | 30.2 | 75.1 | 53.9 | 74.4 | -20.5 (-28.5 to -13.4) |

## Speed and tokens

| set | seconds a page, median / mean / 90th / max | total minutes | input tokens (image + prompt), median (min-max) | image tokens (tokenCount) | output tokens, median / max |
|---|---:|---:|---:|---:|---:|
| The owner's 96 | 9.5 / 32.1 / 80.5 / 90.8 | 51 | 244 (244-276) | 131 on 53, 147 on 41, 163 on 2 | 369 / 4102 |
| 100 Latin pages of the 440 reference set (25 from each of L5-L8) | 76.7 / 92.7 / 94.6 / 4240.2 | 155 | 244 (244-260) | 131 on 67, 147 on 33 | 4102 / 4102 |

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
| p057 | 256 | 256x191 | 67 | 125 |
| p057 | 512 | 512x382 | 195 | 253 |
| p057 | 768 | 768x573 | 131 | 189 |
| p057 | 1024 | 1024x765 | 131 | 189 |
| p057 | 1536 | 1536x1148 | 131 | 189 |
| p057 | 2400 | 2400x1793 | 131 | 189 |
| p057 | 4000 | 2400x1793 | 131 | 189 |
| p010 | 256 | 85x256 | 35 | 93 |
| p010 | 512 | 172x512 | 131 | 189 |
| p010 | 768 | 257x768 | 163 | 221 |
| p010 | 1024 | 343x1024 | 163 | 221 |
| p010 | 1536 | 515x1536 | 163 | 221 |
| p010 | 2400 | 804x2400 | 163 | 221 |
| p010 | 4000 | 804x2400 | 163 | 221 |

## Disagreement with Apple Vision as a routing signal

Risk = 1 − NES(on-device text, Vision text), 0 agreement when either failed. AUC 0.5 is chance. On all pages a failure is the worst risk by construction, so "this model failed" is 1.00 by definition; the answered-only columns drop the failures and are the honest test of the signal; they were added after the 96 were read (post hoc).

| set | label | positives, all | AUC, all pages | positives, answered | AUC, answered pages |
|---|---|---:|---:|---:|---:|
| 96 | this model NES < 70 | 65 | 0.97 | 32 | 0.93 |
| 96 | this model NES < 90 | 85 | 1.00 | 52 | 1.00 |
| 96 | this model failed | 33 | 1.00 | 0 | – |
| 96 | Apple Vision NES < 70 | 21 | 0.59 | 16 | 0.82 |
| 96 | Apple Vision NES < 90 | 37 | 0.51 | 29 | 0.75 |
| 100 | this model NES < 70 | 96 | 1.00 | 41 | 1.00 |
| 100 | this model NES < 90 | 100 | – | 45 | – |
| 100 | this model failed | 55 | 0.94 | 0 | – |
| 100 | Apple Vision NES < 70 | 75 | 0.61 | 34 | 0.98 |
| 100 | Apple Vision NES < 90 | 99 | 0.30 | 45 | – |

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
- **Selection.** The 96 are every accuracy page; the 100 are a seeded draw, 25 from each of the 440 reference set's four Latin-script strata (L5-L8, where Vision's readings are cached; not the 895's nine strata), made before any reading (SEED in the script); Deaver is the development box seg_window_gateway already read at K = 3. None chosen by a route's reading or by ABBYY text. Every page where Apple Vision (26.6) read fewer than 20 words was replaced at the draw (19 of them, 4 tagged Handwritten; `ocr-truth.md`), so the 96 hold no page Vision reads as empty, and every comparison with Vision on them is on pages Vision could read.
- **Comparison.** Apple Vision on the same images (the shipped free reader), its macOS 27.2 re-read (W46.vision-27-reread), so both readers ran on the same OS build; for segmentation, Gemini 3.7 Flash's k3-t and k3-it on the same windows and prompt. The on-device model gets a plain transcription prompt where the panel's routes get the KIND/TEXT prompt; that difference is the route as an app would call it, and is named here.
- **Noise.** n = 96 and 100 pages, paired bootstrap intervals on the page differences. The rerun floor on the 96 is `ocr-rerun-noise.md`'s: a gap under 0.49 NES points, or a paired interval across 0, is a tie. Greedy decoding on one Mac; one reading of each page. Segmentation n = one box (149 pages), intervals over its truth documents.
- **Scope.** One Mac, one OS build, one prompt; the 100 are Latin script only, from L5-L8 of the 440; text-only segmentation on one box, not the three. The loops-cut score, the answered-page groups and intervals and the answered-page AUCs were added after the 96 were read. Apple may change the model with an OS update, so these figures are for macOS 27.2 (26B123), both readers.

