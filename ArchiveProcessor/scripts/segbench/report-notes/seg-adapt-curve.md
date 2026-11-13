## Findings (2026-10-23; figures restated on the owner-ruled truth, unsure gaps unscored, 2026-10-31)

`seg_adapt_curve.py report` reads this file (W46.seg-report-refresh): edit it when the figures it quotes move.

1. **doc-split-v1 is not the laptop segmenter.**
   - **Zero-shot it under-splits every box.** Pages in an exact document are 10.2-42.5% on the owner boxes, 0.8% on
     Lincoln (3 of 77 known boundaries found) and 18.8% on CREST (7 of 29).
   - **Its boundary logits rank boundaries better than its threshold places them** (AUC 0.87 on Lincoln and 0.91 on
     CREST in the 2026-10-23 run, on the truth before the owner's rulings; not recomputed in the tables below). The
     miss is calibration more than ranking.
   - **Refit on the development boxes, it still trails the 2B.** The refit covers the six head and CRF parameters
     plus the beta calibration. It reaches 22.6-61.3% on the owner boxes, 32.2% on Lincoln and 28.1% on CREST.
   - **On the test boxes, under options.md's rule, it does no better than checking every gap.** It reaches 28.2%
     unchecked, and its fitted flag level checks nearly every gap (86.8 per 100 pages). The 2B gets 98.8% after
     78.8 checks.
   - **As a disagreement partner it flags too much.** It disagrees with the 2B on 11.5-27.6 gaps per 100 pages.
   - The laptop profile keeps the corpus-trained 2B.
2. **A few labels buy little beyond the gaps they correct, and they can hurt.** (Single random draws differ by the
   bracketed 10th-90th percentiles; differences inside them are not gains.)
   - **Stanton.** The 2B's threshold-and-prior refit lowers held-out errors from about 10.1 to 6.8-7.5 per 100 gaps
     for k = 25 to 200, and pages exact 3 to 4 points beyond what the corrected gaps give (80.5% against 77.2% at
     k = 25; on the owner's 2026-11-13 corrections, W46.seg-truth-owner-fixes; before them under a point).
   - **Lincoln.** At k=25 the same refit takes pages exact from 42.2% (the corrected gaps alone) to 55.7% and errors
     from 17.5 to 14.0. It then stays at about 14-16 errors whatever k is. The over-splits that remain are confident
     ones, which no threshold reaches.
   - **Boxes the 2B already does well.** The refit is flat or harmful. On CREST at k=25 pages exact falls from 84.2%
     to 76.0% while held-out errors barely move (3.3 to 3.8): the gaps it flips merge long documents.
   - **What follows for the kit.** A refit must be scored on the box's held-out gaps and kept only when it helps,
     which matches A §4's design.
   - **doc-split-v1's per-box refit.** It gains most (Dean 44.9% to 75.4% at k=100) and still stays far below the 2B.
3. **The review screen's rule is disagreement with a second model, not the 2B's own confidence.**
   - **The 2B's confidence is close to random on the hard boxes.** Checks per 100 pages to reach 98%: Stanton 76.0
     against 88.5 for random order; Lincoln 96.2 against 95.1.
   - **Against the 27B teacher (local on a 32 GB Mac).** Checks to 98% are 8.9 (Dean), 18.1 (Deaver), 5.0
     (Herrnstein), 76.8 (Stanton) and 98.4 (CREST, where the 2B's remaining errors need near every gap to reach 98%).
     On Lincoln it fails (96.2), because the teacher over-splits the same manuscripts.
   - **Against the cloud partner it is best or tied on every box but Herrnstein** (11.5 checks against the
     teacher's 5.0). Lincoln needs 54.8 checks (Claude), Stanton 76.8 (Gemini), Dean 8.4.
   - **At 10 checks per 100 pages on Stanton:** against the cloud partner 93.0% of pages exact, against the teacher
     88.9%, the 2B's confidence 84.8%, random 76.6% (rescored on the owner's 2026-11-13 corrections; before them 90.5%,
     86.0%, 82.7% and 77.0%, the same order).
   - **A Vision page-kind change adds little.** Over the 2B's confidence it helps at small budgets on Deaver and
     RG165 (B=10) and Stanton (B=25, though it trails at B=10), ties or trails elsewhere, and never reaches the
     disagreement rules on Stanton.
   - On Lincoln and CREST these figures are conditional on the 2B's own call at the owner's unsure gaps, which are
     never offered for checking (W46.seg-unsure-mask).
4. **Not run here.**
   - **The LoRA continuation of the 2B.** Judged nice-to-have at its Sherlock review and filed as W46.seg-adapt-lora.
     The cheap refit leaves Lincoln's confident over-splits, but one 260-gap box cannot measure a 200-gap LoRA, and a
     cloud voter already settles the route there. The useful form of the test needs a second box of Lincoln-like
     material.
   - **Few-shot examples in the window prompt.** These are W46.seg-adapt-curve-paid (gateway), reported in
     `seg-adapt-fewshot.md`.
