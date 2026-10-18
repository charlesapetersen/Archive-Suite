# Segmentation, proved end to end (W36.seg-opt-proof, 2026-10-12)

Two real folders from the Herrnstein box, through the Processor's own window stage (box/folder confirmation, the
windows, the flagged pass, the skim) with the production transports, by `scripts/test-segmentation-proof.sh`
(`SegmentationProofDriver`). The driver plays a careful user: it answers each flagged gap from the folder's truth
and accepts the skim unchanged. Herrnstein is a development box, so these folders were tuned on; they prove the
build works and are not a test of the shipped figures (those are in `options.md`).

| run | folder | pages exact, no checking | flagged | after checking | unflagged wrong | tokens (in / out) | cost | time |
|---|---|---|---|---|---|---|---|---|
| Gemini, by key | 19-39 | 18 / 21 | 0 of 20 | 18 / 21 | 1 | 85,502 / 3,509 | $0.077 | 16 s |
| Claude, by key | 19-39 | 18 / 21 | 0 of 20 | 18 / 21 | 1 | 164,532 / 3,535 | $0.364 | 15 s |
| Claude, by plan | 19-39 | 18 / 21 | 0 of 20 | 18 / 21 | 1 | — | plan: five-hour 4% → 5%, week 83% → 83% | 39 s |
| Claude + Gemini (Claude by plan) | 19-39 | 18 / 21 | 0 of 20 | 18 / 21 | 1 | Gemini 85,502 / 3,703 | $0.078 + plan 5% → 6% | 82 s |
| Gemini, by key | 76-105 | 30 / 30 | 6 of 29 | 30 / 30 | 0 | 119,697 / 4,904 | $0.108 | 23 s |
| Claude, by plan | 76-105 | 30 / 30 | 2 of 29 | 30 / 30 | 0 | — | plan: five-hour 6% → 8%, week 83% → 83% | 55 s |

Money spent: **$0.63** at list price (Gemini $0.26, Claude by key $0.36). Each run's API tokens were metered from
the replies, the plan runs' meter from `claude`'s `rate_limit_event`. Every run checked that the stage finished,
no gap was left without an answer, every answered gap reached the jobs, and that each provider's calls went by the route chosen
(no Anthropic API call on a plan run, no plan call on a key run).

What it showed:
- **All four routes work against the live services**, including the mix sending Claude through `claude` and Gemini
  by key in one run.
- **Every route left one confident, unflagged error on 19-39**: the kind of error only the skim can catch, as
  `options.md` says. (The driver does not record which gap it was.)
- **The plan route's notional price is about three times the key route's** for the same windows ($1.17 against
  $0.36 on 21 pages), because `claude` reads each page through its Read tool. That is the
  `subscription_route_notional_usd_per_1000_pages` the chooser already shows; it is not money.
- **The first-run plan question was not asked**: 21 and 30 pages moved the five-hour meter 1-2 points, under the
  3 points or 100 pages that ask (usage.md step 3), and the calibration was `notYet`. The driver puts the app's
  stored calibration back after its runs.

The GUI half ran in the Tart VM: the full Processor UITest suite, with `testFlaggedBoundaryPassNeedsEveryAnswerBeforeDone`
(the flagged pass) and the new `testSegmentationChooserShowsEachApproachWithFiguresAndCost` (the chooser in Process
Files: every approach offered; Gemini's figures, cost and "Needs a Gemini API key."; ChatGPT's reason; back to Full
manual). Getting there needed `OCRView.body` split: since `W36.seg-opt-subscription` added the plan alert, the VM's
compiler could no longer type-check it, so the Processor VM lane had been red on main.

## The real local 8-bit build (W41.app-local-seg-proof, 2026-10-17)

The corpus-trained Qwen3.5 2B, `seg-qwen3.5-2b-8bit`, now completes the same app stage through a real
`mlx_vlm.server` on the 18 GB M3 Pro. No API key, money, download, host window or real-corpus write. The
21 input pages are scratch copies from the development fixture, with its cached Vision text. The driver
confirms the folder photo, answers flagged gaps from truth, and accepts the skim unchanged.

| route | exact pages unchecked | flagged | changed by review | exact after review | unflagged wrong |
|---|---:|---:|---:|---:|---:|
| App, local 8-bit 2B | 16/21 | 16/20 | 2 | 21/21 | 0 |
| Cached full-box bench, sliced to 19-39 | 16/21 | 16/20 | 2 | 21/21 | 0 |

The app's denominator includes the folder photo: the bench's document-only measure is **15/20 unchecked**.
Both errors are flagged: after original page **22**, a continuation should be a start; after **29**, a start
should be a continuation. The 16 checks include the confidence tie at the shipped level, 0.995.

All **eight expected windows** returned parsed replies; the ninth HTTP completion is the one-token warm-up.
The independent Python bench (`method_window.combine` and `assemble`, truth photos) recombines the retained
window votes and matches every proposed and final boundary, flagged id/confidence, truth value and score total.
A regression deliberately drops one window whose neighbours cover all its gaps: the stricter recorder catches
it even though no gap has confidence zero. The old proof's zero-confidence check alone did not establish that
individual windows all answered.

The historical full-box comparison agrees here, but is not a required identity: isolating the folder renumbers
its pages 1-21 and clips the first/last windows. Its original-page ranges are 19-22, 19-25, 22-28, 25-31, 28-34,
31-37, 34-39 and 37-39; the full-box bench used outside context at 16-22, 34-40 and 37-43. No prompt, weights or
flag level was tuned for this check, and no locked test box was rerun. This proves the app path, not a new
accuracy estimate or a claim that every local-model mistake is flagged elsewhere.

Reproduce after the documented Debug build, outside the sandbox:

```sh
bash scripts/test-local-segmentation-proof.sh --output /tmp/new-local-seg-proof
python3 -B scripts/segbench/compare_local_segmentation_proof.py /tmp/new-local-seg-proof/result.json
python3 -B -m unittest discover -s scripts/segbench/tests -p test_local_segmentation_proof.py
```

The wrapper starts its own loopback-only server and the app under **one validated heavy-lock holder**, so
there is no server/proof lock collision. It uses local weights with downloads disabled, requires normal memory
pressure and 4 GiB reclaimable before starting, and stops on a 12 GiB tree RSS/physical-footprint cap, 2 GiB
swap growth or critical pressure. It measures Metal's physical footprint as well as RSS. Both process groups
are terminated and reaped before releasing the lock; lifecycle tests cover an exited leader's orphan, a TERM
ignorer, an already-exited group, an app report and a crash before the report. Inherited blocked TERM/INT/HUP
are unblocked in the supervisor. Bash no longer signals a possibly recycled app PID.

The retained `local-seg-proof.json` contains boundaries and counts, not OCR, image bytes or free-form model
cues. `local-seg-proof-runtime.json` records the measured runtime and model fingerprints. Runtime: mlx-vlm
0.7.4, MLX 0.32.3, Transformers 5.18.0, Python 3.12.13; 8-bit affine quantization, group size 64. The first clean
run took **125 s in the app, 134.2 s including supervision**; peak summed footprint **6,681 MB** (server plus
app and supervisor), RSS 1,975 MB, no swap growth, pressure normal. This whole-process figure is distinct from
the bench's 4.4 GB MLX allocation peak. Publishing the weights remains W41.app-local-seg-publish.

A second clean run through the Python-owned app path reproduced the same decisions, flags and token totals: **124 s**
in the app, **133.6 s** with supervision; peak summed footprint **6,774 MB**, RSS 3,683 MB, no swap growth, normal
pressure. The retained JSON is this repeat. All six lifecycle regressions pass, including outer shutdown of a
TERM-ignoring app in its separate group; inner app cleanup is immediate and the outer supervisor allows it a
longer teardown budget. Deliberately corrupting a window, proposal, final boundary or flag confidence makes the
independent comparison fail. Engine and chooser self-tests pass; the Debug build has no new warnings (only the
pre-existing AppIntents metadata notice).
