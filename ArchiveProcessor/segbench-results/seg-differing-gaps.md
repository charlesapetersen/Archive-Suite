# The gaps that decided the differing segmentation pairs (W46.seg-differing-gaps-sheet)

Owner, 2026-11-19 walkthrough: confirm the differing pairs. `seg-pair-ties.md` §SEG-11 found that, of the 16 route
pairs the paired interval separates, the documents right in one route only were decided at five Stanton gaps no one had
re-judged since the capture labels (12|13, 20|21, 170|171, 227|228, 232|233; 20|21 in all 16 pairs, the other four in
the 12 against the 2B), every one for the winner. Neutralised, 7 of the 16 would have tied: every Gemini route over the
students.

The owner answered a blind sheet (`seg_differing_gaps.py sheet`, the pages either side, no route call or truth shown)
on 2026-11-19 at 08:39: **all five are the same document**, as the truth already had them. No note. Nothing in the
truth changed, so no result was rescored; the five gaps now count as re-judged (`seg_pair_ties.rejudged()` reads this
item's record, `seg-differing-gaps.json` `fold.keys`).

## Each pair's verdict before and after

The pairs' own edges and intervals are unchanged (same truth, same answers). What moved is SEG-11: no document in any
differing pair is now decided at an un-re-judged gap, so the neutralised edge is the edge itself.

| a | b | verdict (interval) before → after | neutralised before → after |
|---|---|---|---|
| chatgpt-gpt6.1-sol, mix-claude-chatgpt, claude-sonnet5.5 | qwen3.5-27b-teacher, both 2B rows | differs → differs | differs → differs |
| gemini3.7-flash-gateway | qwen3.5-27b-teacher, both 2B rows | differs → differs | **tie → differs** |
| gemini3.8-flash-text, gemini3.8-flash | both 2B rows | differs → differs | **tie → differs** |

All 16 stay differing; the 7 that neutralising would have tied now hold (e.g. Gemini 3.7 over the 27B teacher
+7.69 [+0.33, +15.91], Gemini 3.8 Flash over the 2B +8.00 [+2.40, +14.61]). No pick moves:
`settings_routes.py --check` passes on the unchanged table, and the 'with the floor' column is reported only, as the
owner kept the interval-only rule (2026-11-18).

## Measurement card

- **Truth.** Owner-ruled Stanton and RG165 labels with W46.seg-truth-owner-fixes' corrections; the five asked gaps now
  owner-confirmed a second time, blind. No drafter or route's call was shown.
- **Selection.** The five gaps were chosen because they decide discordant documents in the differing pairs, that is by
  where routes disagree; the confirmation removes doubt at those gaps only, not elsewhere in the boxes.
- **Comparison.** Same pages, windows and frozen rules as `seg-pair-ties.md`; nothing rerun.
- **Noise.** As `seg-pair-ties.md`: the paired interval covers document sampling; the student rerun floor (3.2 points)
  is reported only.
- **Scope.** Confirms the truth at these five gaps; gaps where routes agree with each other are the audit's
  (`seg-truth-audit.md`), not this item's. $0, no model call or upload.
