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
