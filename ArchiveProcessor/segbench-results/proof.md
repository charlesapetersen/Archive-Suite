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
every window answered, every answered gap reached the jobs, and that each provider's calls went by the route chosen
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
