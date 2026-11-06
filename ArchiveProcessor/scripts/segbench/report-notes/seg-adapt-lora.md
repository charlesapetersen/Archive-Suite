## Findings

**The question.** A user reviews the start of a box of a new material and corrects the 2B's calls on its first k
gaps. Does a LoRA continuation of the corpus-trained 2B on those corrections (plus three corpus windows replayed for
each correction window) make fewer errors on the next box of the same material? Box 1 is Lincoln (catalogue
positions 2-73), box 2 the next 70 items of the same series (positions 74-143). Nothing trained on box 2.

**At k = 200 the continuation carries over to the next box, by far more than a rerun moves.** On box 2 the errors
fall from 17.2 to 4.9 per 100 gaps, a change of -12.3 (-18.8 to -7.4); false splits fall from 41 to 10, pages in an
exactly right document rise from 52.1% to 86.8% and PQ from 0.522 to 0.861. A rerun of the same requests moves the
2B by +1.4 per 100 gaps (3 of 207 decisions). On box 1's 59 gaps after the training ones the change is -5.1 (-14.7
to 0.0), the same direction but too few gaps to separate from noise.

**At k = 50 it buys little.** Box 2: -1.6 (-4.5 to +1.2), a tie. Box 1 after 50: -2.9 (-6.3 to -0.4), about twice
the rerun floor. Fifty corrections are 16 training windows and 9 changed decisions, too few to move the 2B's
confident over-splits; this matches W46.seg-adapt-curve, where a refit on the same gaps barely moved them.

**The rule set before scoring is not met: each arm loses a start.** "Yes, offer adaptation" needed no loss of start
recall on either box. At k = 200, box 2 finds 67 of 69 catalogue starts against the 2B's 68: the 2B's 0.90 at gap
86|87 becomes 0.05, while the 2B's coin-flip 0.50 at 219|220 (counted a start by the threshold) becomes a confident
0.99. On box 1 after 200 the one start inside an item (222|223) that the 2B held at exactly 0.50 becomes 0.05. At
k = 50, box 2 loses two catalogue starts (86|87 and 219|220) and box 1 none. One start is within what a rerun moves
(FarmShare's answers find 6 of 6 starts inside items after gap 50 where Sherlock's find 5), but the direction is
the one the scoring conditions warned about: the continuation learns to merge, and box 2's truth cannot see a start
inside an item that it misses.

**What this means for the settings (an input to W46.review-phase4, not a decision).** After a reviewed box of about
200 corrected gaps, a LoRA continuation is a real option for the next boxes of that material: it removes about
seven in ten of the 2B's errors on box 2. It is not one to offer as unchecked: it trades a few starts for many
fewer false splits, so the review screen's flagging (W46.seg-adapt-curve: disagreement with a second model) should
stay on after adaptation. Fifty corrections are not enough to offer it. The cost was about 1.4 GPU-hours on
Sherlock (training 15 and 54 minutes, each scoring run under 5 minutes) and $0.45 of gateway calls for box 2's
truth.
