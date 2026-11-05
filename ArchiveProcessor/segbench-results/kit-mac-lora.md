# W46.kit-mac-lora — can the kit train the 2B on a Mac?

**Answer: not on an 18 GB Mac.** No run of `mlx_vlm.lora` on the shipped Qwen3.5-2B 8-bit segmentation base finished a
single training step on a real window (page images plus Apple Vision text). Every image-window run was stopped in its
first step's backward pass. Short text-only examples did train. Closed by the owner on 2026-11-04 with this as the item's
answer; the 32 GB arm stays unrun unless such a Mac exists (gap audit, owner question 4).

Machine: Mac15,7, Apple M3 Pro, 18 GB, macOS 27.2. Runs 2026-11-04 05:00–12:57 by two engine sessions, under the
Vision OCR lab's memory guard (`run-guarded.sh`, given `--rss-gb 8` by the wrappers) and the engine's session guard
(11.7 GB for all of a session's processes while the Mac is under memory pressure). Code: `scripts/segbench/kit_mac_lora.py`
(`seg-data`, `render`, `train`, `probe`, `measure`); wrappers and every log in [`kit-mac-lora/`](kit-mac-lora/).
$0, no model call, no corpus write.

## What was measured

Training settings (`kit-mac-lora/train.sh`): batch 1, LoRA rank 8 (alpha 16), `--grad-checkpoint`,
`--train-on-completions`, `--max-seq-length 16384`, learning rate 1e-4.

| Run | Tokens | Result |
|---|---|---|
| `probe-text-1500`: text only, one LoRA step | 481 | step done, peak 3.50 GB (MLX) |
| `probe-text-4000`: text only, one LoRA step | 1,121 | step done, peak 4.52 GB |
| `pt4000`: text only, forward in train mode | 1,121 | done, peak 2.94 GB |
| `pt4000f`: text only, full fine-tune step (`--full`) | 1,121 | stopped at 9.35 GB process memory |
| `probe-text`: text only | 2,849 | forward 3.28 GB; stopped in the step at 8.43 GB |
| `probe-p1`: one page per window | 2,881 | stopped at 9.05 GB |
| `probe-seg-20-p2`: two pages per window | 4,385 | vision 3.56, forward 3.58 GB; stopped in the step at 8.30 GB |
| `probe-seg-20`: a full window | 11,777 | vision 3.96, forward 3.96 GB; stopped in the step at 8.52 GB |
| `seg-20-p2-r8-i5`: 20 two-page windows, 5 iterations | ~4,400 | stopped before iteration 1 at 8.26 GB |
| `seg-20-r8-i20`: 20 full windows, 20 iterations | ~9,700 | stopped before iteration 1 at 10.25 GB process memory, critical pressure; the engine's guard saw 12.6 GB for the session |
| a second session on the same arm | ~9,700 | the engine's guard stopped it at 13.6 GB for the session |

The real training windows (`tokens-seg200.txt`, 200 rows of the agree set at 1,024 px): median 9,672 tokens, minimum
3,764, maximum 11,808; a seven-page window carries 5,376 image tokens and trains on 350.

## What it says

- **The forward pass is cheap and the backward pass is not.** Weights are 2.5 GB; a full window's vision tower and
  forward pass peak at about 4 GB. The step is where every image run stopped.
- **One cause is in the model.** Qwen3.5's Gated DeltaNet layers use a custom Metal kernel that has no gradient
  (`probe-p2`: `[Primitive::vjp] Not implemented for CustomKernel`). In train mode mlx-vlm takes the kernel-free
  path, which holds far more memory through the backward pass.
- **The true peak was not measured, only lower bounds.** Each stop was a guard, at 8 GB for the probes and 11.7 GB for a
  session, not an out-of-memory failure. The two text steps that finished give about 1.6 MB a token above the
  weights [I, a line through two points]; carried to the median window that is about 18 GB, and the image runs
  stopped above that line (2,881 tokens at over 9 GB, against about 7 GB predicted). So a median window needs more
  than a session may use on this Mac, and most likely more than the Mac has.
- **Smaller windows would not answer the kit's question.** Even one page per window did not fit under the 8 GB guard,
  and windows cut down far enough to fit are not the windows the shipped model reads.

## For the settings work (Phase 4)

A Mac-only user with 16–18 GB cannot train the segmentation model on their own pages: the shipped 2B and its cheap
refit are what that profile gets, and fine-tuning goes to a cluster (the kit's Sherlock route, 2B text LoRA 27 minutes
on one L40S) or to a Mac with more memory, unmeasured here. Short text-only LoRA does fit (4.5 GB at 1,121 tokens), so
a text-only adaptation, such as the dating LoRA the audit lists for R2, stays plausible on such a Mac.

## Measurement card

- **Truth.** None needed: the measure is whether a step completes and its peak memory, read from MLX's own peak
  counter and the guards' process-footprint lines in the logs.
- **Selection.** The windows are W46.kit-mac-lora's `seg-data` build of the agree set, the same windows the shipped
  2B was trained and scored on, with Apple Vision text in place of ABBYY's (no ABBYY text). Not chosen by any tested
  route.
- **Comparison.** One base, one set of settings; the text probes vary only sequence length; the full fine-tune
  (`pt4000f`) is the one change of method.
- **Noise.** Each figure is one run. Peak memory is close to deterministic for a fixed input on one machine, but the
  stops depend on what else was running (pressure was critical for `seg-20-r8-i20`), so the stopping points are lower
  bounds, not peaks.
- **Scope.** Settles the 18 GB M3 Pro with mlx-vlm and this base and these settings as of 2026-11-04. Does not settle a
  32 GB or larger Mac, a future mlx-vlm with a gradient for the Gated DeltaNet kernel, or other bases. Those would
  reopen it.
