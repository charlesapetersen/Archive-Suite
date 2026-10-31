# OCR rerun noise on the owner's 96 (W46.ocr-rerun-noise)

Each route read the same 96 scored pages (the 99 settled jobs less the three agreement-only letters) again with nothing changed: the same images, prompt, temperature 0 and settings. Run 0 is the reading already in the bench (Gemini: W46.fix-ocr-scorers-paid on 2026-10-23; Qwen: W41.mac-local-measure on 2026-10-15); the new runs were read for this item on 2026-10-30. Gemini was read three times. Qwen was read twice: its run 1 matched run 0, read 15 days earlier, byte for byte on every page, so a third greedy reading could not change its spread, and on 2026-10-31 the Mac never had the 8 GB free that the memory guard asks for (run 1 peaked at 8.5 GB). `ocr_rerun_noise.py mlx --run 2` still reads it, and the report takes it in. NES is the panel's score (`ocr_panel_score.score`) against today's truth. **Strict** counts a failed page as 0; **answered** averages the pages that run answered. Reproduce: `ArchiveProcessor/scripts/segbench/ocr_rerun_noise.py`.

## Gemini 3.7 Flash (Stanford gateway, temperature 0, low reasoning)

| run | pages read | NES strict | NES answered |
|---|---:|---:|---:|
| 0 | 96/96 | 96.74 | 96.74 |
| 1 | 96/96 | 96.74 | 96.74 |
| 2 | 96/96 | 96.49 | 96.49 |

Run-to-run spread of the 96-page mean: strict range 0.24 points (SD 0.14), answered range 0.24 points (SD 0.14).

| runs | identical page texts | failure flips | mean / max page move (answered) | paired Δ strict (95% CI) | paired Δ answered (95% CI) |
|---|---:|---:|---:|---:|---:|
| 1-0 | 24/96 | 0 | 0.41 / 3.78 | -0.00 (-0.18 to +0.17) | -0.00 (-0.18 to +0.17, n 96) |
| 2-0 | 22/96 | 0 | 0.77 / 18.17 | -0.24 (-0.78 to +0.20) | -0.24 (-0.78 to +0.20, n 96) |
| 2-1 | 27/96 | 0 | 0.63 / 15.72 | -0.24 (-0.72 to +0.19) | -0.24 (-0.72 to +0.19, n 96) |

| kind | pages | strict mean per run | strict range | answered range |
|---|---:|---|---:|---:|
| handwritten | 16 | 95.07 / 94.80 / 94.77 | 0.30 | 0.30 |
| mixed | 2 | 83.84 / 82.62 / 74.76 | 9.08 | 9.08 |
| printed | 28 | 94.91 / 94.90 / 95.03 | 0.12 | 0.12 |
| typewritten | 50 | 98.81 / 98.95 / 98.74 | 0.21 | 0.21 |

## Qwen3-VL 8B 4-bit (mlx-vlm on this Mac, temperature 0)

| run | pages read | NES strict | NES answered |
|---|---:|---:|---:|
| 0 | 92/96 | 89.66 | 93.56 |
| 1 | 92/96 | 89.66 | 93.56 |

Run-to-run spread of the 96-page mean: strict range 0.00 points (SD 0.00), answered range 0.00 points (SD 0.00).

| runs | identical page texts | failure flips | mean / max page move (answered) | paired Δ strict (95% CI) | paired Δ answered (95% CI) |
|---|---:|---:|---:|---:|---:|
| 1-0 | 96/96 | 0 | 0.00 / 0.00 | +0.00 (+0.00 to +0.00) | +0.00 (+0.00 to +0.00, n 92) |

| kind | pages | strict mean per run | strict range | answered range |
|---|---:|---|---:|---:|
| handwritten | 16 | 89.16 / 89.16 | 0.00 | 0.00 |
| mixed | 2 | 16.84 / 16.84 | 0.00 | 0.00 |
| printed | 28 | 91.69 / 91.69 | 0.00 | 0.00 |
| typewritten | 50 | 91.59 / 91.59 | 0.00 | 0.00 |

## The tie rule

A gap between two routes on the 96 is a **tie** when it is under twice the larger rerun range of the routes compared (strict or answered, whichever is quoted), or when its paired 95% interval crosses 0. Both tests apply: the rerun range catches the route's own instability, the paired interval catches page-sampling noise, which a deterministic route still has. Twice the range measured here: Gemini 3.7 Flash 0.49 points, Qwen3-VL 8B 4-bit 0.00 points. Qwen3-VL 8B 4-bit gave the same text on every page in every run (greedy decoding on one machine is deterministic), so for it, and for a local greedy route like it, only the paired interval applies. A route with no rerun of its own takes the larger of these (a hosted model is held to Gemini's, a local greedy one to Qwen's) until it is measured. Per kind, the kind's own range applies; a kind of a dozen pages moves far more than the whole.

Gateway spend: 300 calls, about $1.14 at Gemini 3.8 Flash's list rate (an estimate; the gateway does report its own figure in an `x-litellm-response-cost` header, which `gateway_gemini.py` does not yet record), Stanford PTA. The MLX runs cost nothing.

**The gateway caches.** It is LiteLLM, and it answers a byte-identical request from a response cache: the first run 2 came back in a median 1.3 s a page (run 1: 8.0 s) with run 1's exact text and tokens on all 99, a copy, not a reading. It is kept aside (`run2-gateway-cached`) and run 2 was read again with the body field `"cache": {"no-cache": true}`, which skips it (median 7.1 s; the request Google sees is unchanged). Run 1 was read before this was known; it was live throughout (no call under 2.7 s, its 22 texts that match run 0 took 3-15 s). Any gateway arm that repeats a request, a retry included, should send that field.

## Measurement card

- **Truth:** the 96's adjudicated truth, the panel's (`ocr_truth`), read today for every run. The figure is the difference between runs of one route against one fixed truth, so a bias in the truth toward a drafter moves every run of that route alike and cancels; it does not cancel in a gap between two routes, which is what `ocr-truth-bias.md` addresses.
- **Selection:** none: all 96 scored pages, every run.
- **Comparison:** the same images, prompt, temperature, reasoning and token cap within each route. Only the gateway cache field differs (run 2), and it never reaches the model. Run 0 of Gemini was read on 2026-10-23, runs 1 and 2 on 2026-10-30, so 1-0 and 2-0 can include a provider change in that week; 2-1 is the same-day pair. The public 895 were not reread (the item measures the 96, where routes are chosen).
- **Noise:** this is the noise figure. Gemini's three runs make its range a rough estimate in its own right (a fourth run would likely widen it), and the per-kind ranges rest on 2-50 pages; the 2 mixed pages are anecdote. Qwen's zero rests on two runs 15 days apart, identical on every page, which is the evidence for determinism, not a sample of a spread.
- **Scope:** two routes. Other hosted models, other temperatures and other local runtimes are not measured; the rule above lends them these figures until they are. It says nothing about the 895.
