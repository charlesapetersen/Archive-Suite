# Early read: Claude over page windows (W36.seg-window), development set

Written 2026-10-05, as the plan's EARLY READ rule asks: the development numbers for the first window method, and
the review load it would need to reach 98%, so the owner can decide whether to stop the bake-off here.

## What was run

Claude Sonnet 5.5 through Claude Code on the owner's subscription, judging every boundary in overlapping windows
of seven page photos, with the Apple Vision text of each page. Every boundary was judged in two windows and the
two judgements were averaged. It ran on the three development boxes only (Dean, Deaver and Herrnstein, 551
pages). Stanton and RG 165 were not touched.

These are development numbers, and they flatter the method somewhat. The prompt was written after earlier bench
work had read pages from these boxes, though it was not revised against its own errors. 551 pages is a small
sample: one more wrong boundary can move the pooled figure by up to about a point.

## The numbers

Pages in an exactly right document, with the model labelling the box and folder photos itself:

| | Dean | Deaver | Herrnstein | pooled |
|---|---:|---:|---:|---:|
| window method | 82.7% | 96.5% | 89.5% | 88.8% |
| spring-v1, the prompt the app ships | 84.7% | 84.4% | 85.6% | 84.9% |

The window method is about four points better than the shipped prompt overall. It makes far fewer false splits
(9 against 24) and the same number of false merges (8). Most of the gain is on Deaver, the newspaper clippings.
On Dean it is slightly worse. Giving it the true photo labels changes nothing.

## Review load to reach 98%

To reach 98% of pages in an exact document across the three boxes, you would have to check about 85 boundaries
per 100 pages. That is nearly every boundary in the box. The simulation checks the boundaries the model was least
sure of first and corrects each one.

The load is high because the model's confidence does not pick out its mistakes. Of the 17 boundaries between
document pages that it got wrong, 7 were ones it rated 95% sure or higher. The second window does not help
either: the two windows disagreed on only 4 of 494 boundaries.

## Your label check matters here

Six of the 17 errors fall at pages already on your list of suspected label errors: Dean 13 and 15, and the
possible one-row shift at Herrnstein 19 to 25. At each of them the model sides with the suspicion, and six of
the seven high-confidence errors are among them. If those labels are corrected as the truth-check suggests (you
have not ruled on them yet), the window method scores 90.7% pooled, and reaching 98% takes about 27 boundaries
reviewed per 100 pages instead of 85. The other high-confidence error, Dean 122, stays.

## Verdict

On the labels as they stand, this method falls short of 98%, and with review it only gets there if you check
almost every boundary. That is not usable. The plan's guide said that if the best single method scores under
about 90%, combining methods is unlikely to reach 98% at a review load worth having. It scores 88.8% as labelled
and 90.7% with the suspected errors corrected, so it sits right at that line.

Even on the corrected reading, about 27 boundaries per 100 pages means checking roughly one gap between pages in four by hand,
which is far from the light review the plan hoped for. The method is the best one tried so far and makes few
errors. What it lacks is a way to point to the boundaries that need checking. The remaining bake-off items are
worth running only if an independent second model disagrees with this one where it is wrong. The next item
(`W36.seg-second`) measures that cheaply. Settling the suspected labels first would make that measurement and
this one more trustworthy. Whether to go on or stop here is your decision.

Detail: `ArchiveProcessor/segbench-results/window-claude-report.md`; summary table:
`ArchiveProcessor/segbench-results/SUMMARY.md`.

## Addendum, 2026-10-05 afternoon — re-scored on the owner's corrected labels

The owner answered the ground-truth check and approved seven label changes (`02-truth-check.md`). Re-scored from
the saved answers, with no new calls, on the development boxes:

| method | pages in an exact document | false splits | false merges |
|---|---:|---:|---:|
| window-claude | 90.0% | 6 | 6 |
| spring-v1 (shipped) | 86.1% | 21 | 6 |
| features-lr | 63.9% | 13 | 62 |
| rule-cues | 57.7% | 96 | 15 |

The review load to reach 98% for window-claude is still 388 boundaries (about 70 per 100 pages): three of its twelve
remaining errors are rated 0.95 or higher. The decisive open question is Herrnstein 19 and 20, the two rows of
the suspected shift the owner has not yet seen: with them corrected as suspected, the same method needs only
**29 boundaries reviewed (about 5 per 100 pages) to reach 98%**, and 1 high-confidence error remains. None of the
methods yet uses the owner's domain cues (show-through, bylines and wire credits, items on top of a page); the
next prompt revision should, which this measurement does not reflect.

## Addendum 2 — the ground truth is now final (Herrnstein 19–20 answered)

With every owner correction applied: window-claude **90.3%** of pages in an exact document on dev (5 false splits, 6
false merges), spring-v1 86.5%, features-lr 64.1%, rule-cues 57.9%. **Reviewing the 34 least-confident boundaries
(about 6 per 100 pages) brings window-claude to 98.1% pooled** (Dean 99.0%, Herrnstein 98.3%, Deaver 96.5%); 98%
in every collection separately takes 147 (about 27 per 100 pages), because Deaver's last errors are high-confidence.
So: close to the owner's bar with a review load worth having, before any use of the owner's domain cues — on the
development boxes only, with a prompt written after reading them. The test boxes (Stanton, RG 165) are still unseen.


## Addendum 3, 2026-10-05 evening — a second model as a voter (W36.seg-second)

What was run: Gemini 3.1 Flash-Lite through the paid API, with thinking set to minimal, over the same
seven-page windows as the Claude method. The prompt was new. It stated your domain cues: show-through,
a small item lying on a full sheet, bylines and wire credits, the full magazine, and runs of empty folder
or box photos. It also stated the approved document rules. The run made 187 calls and cost about $0.67
at the list price. The estimate before the run was about $0.65 to $0.77. No call was made to the larger
Gemini 3.8 Flash.

On its own, Flash-Lite is worse than both earlier methods. It put 84.6% of pages in an exactly right
document, against 90.3% for the Claude window method and 86.5% for the prompt the app ships. Most of
its errors are false splits: it made 27 and missed only 3 boundaries. They cluster in two places. In
Deaver, 17 times, it starts a new article at a photo that your labels keep with the clipping before it,
usually citing a headline it saw. In Herrnstein it splits a run of six figure pages that your labels
keep with the document before them. Reaching 98% with its own confidence would take about 37
reviewed boundaries per 100 pages, against 6 for Claude.

Voting did not find Claude's errors. Where the two models disagree, a boundary would be flagged for
you. That happened at 25 boundaries, about 4.5 per 100 pages. But 22 of those 25 were Flash-Lite's own
mistakes, and they held only 3 of Claude's 11. The other 8 errors are boundaries where both models
made the same wrong call, so voting would accept them without showing them to you. Reviewing the 25
flagged boundaries brings the result to 92.5%. Reaching 98% takes 49 reviews (about 9 per 100 pages),
which is more than the 34 that Claude's own confidence needs.

So this second voter adds nothing. A weak model mostly disagrees where it is wrong itself. The errors
that matter are the ones both models share.

Caveats. These are development numbers only, from Dean, Deaver and Herrnstein. Stanton and RG 165 were
not touched. The prompt was written after reading your notes on these boxes. The model and the prompt
both changed from the Claude run, so this result cannot say how much of the gap is the model and how
much is the prompt. A stronger second model might do better. The confidences Flash-Lite gives are very
coarse, mostly 0.95 or 1.0.

Detail: `ArchiveProcessor/segbench-results/window-gemini-lite-report.md`; summary in `SUMMARY.md`.
