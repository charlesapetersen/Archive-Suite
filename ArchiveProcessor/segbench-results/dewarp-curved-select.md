# A guarded UVDoc reading copy for selection on the owner's bound or curled pages (W46.dewarp-curved-select)

W46.dewarp-guard found the print layer's selection gap on the 24 pages of place-curved-owner that Gemini 3.7 Flash
classed bound or curled: 71.6% of lines pass against 93.5% on their flat pairs, −19.2 (−25.0 to −13.3) paired. It
also measured a guard that keeps UVDoc from cutting own-sheet words. This item scores the guarded UVDoc copy there
for selection, with place-curved-owner's drags, against the route's raw or deskewed copy. It is evidence for the
owner's revisit of call 6 (2026-11-06, no dewarped copy), not a change to it.

Script: `scripts/segbench/dewarp_curved_select.py` (tests: `test_dewarp_curved_select.py`). Figures:
`dewarp-curved-select.json`. No model was called and nothing was spent.

## Verdict

- **On the 24 bound or curled pages, the guarded copy selects a little better than the route's copy.** The guard
  passes UVDoc on 12 of the 24. The guarded pipeline (UVDoc where the guard passes, the route's copy elsewhere)
  passes 74.8% of lines against 71.6%: **+3.2 (+0.4 to +7.7) pooled**, +4.6 (+0.6 to +9.1) as the mean page
  difference. 7 pages are better and 2 worse. On the 12 pages the guard passes, UVDoc lifts the pass rate from 74.8%
  to 85.8%: **+11.0 (+2.9 to +18.2)**.
- **It costs the flat pairs nothing.** The guard passes 10 of the 24 flat pairs. Guarded, they pass 94.6% against
  93.5%: +1.1 (−0.6 to +3.8); 2 pages better, 1 worse.
- **The gap narrows but stays.** Curved page minus flat pair, paired: route −19.2 (−25.0 to −13.3), guarded −15.1
  (−21.1 to −8.6). A dewarp straightens about a fifth of the gap; most of it is still the one level run per line on
  a page the guard holds back.
- **Unguarded UVDoc is no use.** It cuts 199 of the 1,095 curved lines' words (counted as failures). It gives −5.0
  (−16.9 to +8.0) on the curved pages and −3.9 (−7.0 to 0.0) on the flat ones, 12 of the 24 flat pages worse.
- **The owner's two pages are both held back.** On UIUC 00233 (bound) UVDoc would select 26 of 27 lines against the
  deskewed copy's 21, but it cuts 8 own-sheet words, so the guard keeps the route's copy. On UIUC 00149 (curled) it
  cuts 12 own-sheet words and selects 24 of 33 against 33.
- **What this means for the call.** Where the guard lets it through, a guarded UVDoc copy is a real gain for
  selection on bent pages (+11.0), and it removes no own-sheet word by construction. Over all the owner's bound or
  curled pages the gain is small (+3.2), because the guard holds back half of them, the two owner pages included.
  The 2026-11-06 call stands until the owner revisits it.

## The arms

All three arms use the same upright photograph, the same Vision lines and the same blla truth lines as
place-curved-owner (its cached readings; the upright copies were rebuilt and match its sizes on all 64 pages).

| arm | the copy | the layer |
|---|---|---|
| route | raw, or deskewed when the median line angle is 1° or more (place-curved-owner's route) | Vision's lines, one level run per line, written exactly as place-curved-owner wrote them |
| uvdoc | UVDoc 4c9b82b5 (`best_model.pkl`, CPU, the shared torch environment) after Apple's quad | Vision's lines carried through the inverted lattice (`place_geom.lattice_inverse`, `carried_layer`, lab writer) |
| guarded | uvdoc where the guard passes, route elsewhere | as the arm it uses |

- **The route replays exactly.** Its counts equal place-curved-owner's committed rows (lines, passes, broken) on all
  64 pages; the script asserts it.
- **The guard** is dewarp-guard's own-sheet rule. It passes when no Vision word of the raw reading that lies inside
  Apple's quad, or on a Vision line that keeps another shown word, falls outside UVDoc's lattice. It reads no truth.
- **Drags.** place-curved-owner's ink drag on each scored blla line, carried onto the arm's copy. A line with a word
  the copy does not show is a failure (`cut`).
- **Drag ends at the copy's edge.** UVDoc's copy often ends right at the text's left margin, so the first word's left
  edge can lie just off the copy while the word is shown. Such an end is moved along the line to the copy's edge,
  where a reader would start the drag. That moved 21 ends on the 24 curved pages' guarded arm and 13 on the flat
  pairs'. The rule was added after the first run showed those ends. Without it (the ends counted as cut lines) the
  figures are lower but point the same way:
  - curved, guarded: +2.2 (−0.5 to +5.8); passing pages +7.6 (−1.1 to +15.0);
  - flat pairs, guarded: −0.2 (−4.8 to +3.3);
  - pair gap, guarded: −14.1 (−21.5 to −5.9).

## Results

Pass rates are pooled over lines. Δ is against the route on the same pages, with a 95% page bootstrap (2,000 draws,
seed 4611); "page Δ" is the mean of the page-rate differences.

| pages | n | lines | guard passes | route | uvdoc | guarded | guarded Δ pooled | guarded page Δ | better / worse |
|---|---:|---:|---:|---:|---:|---:|---|---|---|
| **curved, bound or curled** | 24 | 1,095 | 12 | 71.6 | 66.6 | 74.8 | **+3.2 (+0.4 to +7.7)** | +4.6 (+0.6 to +9.1) | 7 / 2 |
| **their flat pairs** | 24 | 851 | 10 | 93.5 | 89.7 | 94.6 | **+1.1 (−0.6 to +3.8)** | +0.6 (−1.3 to +2.9) | 2 / 1 |
| curved, classed flat | 8 | 221 | 1 | 87.8 | 84.6 | 87.3 | −0.5 (−1.2 to 0.0) | −0.2 (−0.7 to 0.0) | 0 / 1 |
| all 64 | 64 | 2,448 | 28 | 83.5 | 78.4 | 84.9 | +1.4 (−0.1 to +3.3) | +1.6 (−0.2 to +3.6) | 9 / 7 |

| pages the guard passes | n | route | uvdoc | Δ pooled |
|---|---:|---:|---:|---|
| curved, bound or curled | 12 | 74.8 | 85.8 | **+11.0 (+2.9 to +18.2)** |
| their flat pairs | 10 | 93.5 | 96.6 | +3.1 (−1.9 to +9.3) |

Unguarded UVDoc against the route: curved −5.0 (−16.9 to +8.0), 10 better and 11 worse, 199 cut lines; flat pairs
−3.9 (−7.0 to 0.0), 2 better and 12 worse, 27 cut lines.

**Where the guarded copy loses and gains.** It loses on three pages: s03335 (curled, 22 → 18 of 24, 8 ends moved),
s02883 (bound, 34 → 33) and, on a flat pair, s02113 (17 → 15 of 17, 12 ends moved). The large gains are s01665
(18 → 27 of 33), s01668 (22 → 31 of 34), s01319 (20 → 28 of 31), s03303 (19 → 24 of 24) and, on a flat pair, s00052
(35 → 45 of 45).

## Measurement card

- **Truth.**
  - The lines are kraken blla's, as in place-curved-owner: a baseline segmenter, blind to Vision, not a reader. A
    line's words are the Vision words whose centres lie in its boundary, so an OCR miss is not a selection failure.
  - The classes are dewarp-guard's single Gemini 3.7 Flash reply a page, checked by no one; "curled" is generous.
  - The owner checked nothing in this item.
- **Selection.** place-curved-owner's 64 pages (chosen by its line-angle cue) and dewarp-guard's classes. No tested
  route and no ABBYY text chose a page, and the guard decides from the raw reading and the lattice, never the truth.
- **Comparison.** Every arm has the same image, Vision lines, blla lines, writer and PDFKit drag tool. The route arm
  is place-curved-owner's run, reproduced exactly. The UVDoc arm's drag ends differ only where they fall off its
  copy (above, with the figures both ways).
- **Noise.** Vision's lines are cached, and UVDoc on CPU, the writer and PDFKit's drags are deterministic on an image,
  so the rerun floor is 0. The sets are small (12 to 24 pages), and their intervals say so: the curved guarded
  interval's lower end is +0.4 (and −0.5 without the edge rule).
- **Scope.**
  - This is selection on Vision's own layer, not OCR: no reader read the UVDoc copy. dewarp-guard's NES rows cover
    OCR on the 96 and Real5.
  - The owner's two pages are not helped, because the guard holds both back.
  - UVDoc ran in the shared torch environment, whose lattices sit within about 8 px of enh-dewarp's venv run
    (dewarp-guard.md).
  - The guard checks word centres, so a word whose centre is shown but whose ink is clipped passes.
