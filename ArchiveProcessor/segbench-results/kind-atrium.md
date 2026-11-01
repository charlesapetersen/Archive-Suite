# ATRIUM's page classifier against our kind classifier (W46.kind-atrium)

## Verdict

**Keep the shipped classifier for the hand and for forms; do not replace it with ATRIUM or combine the two. ATRIUM's TEXT has the highest mixed-page recall of the three labels on the 2,000 and is worth keeping as a candidate signal for the mixed flag (W46.mixed-route), not as the kind router.**

- On the 141 typed, printed and handwritten owner pages, ours is right on 137, ATRIUM forced to its six text classes on 121 (paired p 0.0009): it finds every handwritten page but calls typewriting printed. A head on its embedding does better (128) but still below ours (p 0.0352), and adding it to our features does not help (134).
- Routed by the guide on the 96, ATRIUM costs 1.18 NES against ours 1.00: their intervals overlap, because ATRIUM's errors are mostly typewritten called printed, which costs little on these pages.
- On the 895 public pages, which neither was fitted on, ATRIUM hand-only is right on 638 and ours on 723. By stratum (§4) both fail L5 and N4; ATRIUM also misses most of L7's handwriting and L8's and N6's print, where ours holds better.
- Mixed, under the owner's cut: ATRIUM's TEXT finds an estimated 60% of mixed pages at 70% precision; Qwen3.6-27B's mixed 23% at 99%. ATRIUM over-calls mixed on pages with no handwriting (24 of 46 on the sheet) and the two Qwen's few calls are nearly all right but find under a quarter, so neither alone is a mixed filter.
- Speed is not the obstacle: 0.06 s a page on MPS, against about 0.6 s for ours. The obstacles are accuracy on the distinction the guide routes by, a 323 MB download and a non-commercial licence on the base weights.

Measured 2026-11-01 with `scripts/segbench/kind_atrium.py` (header: how to rerun). ATRIUM is `ufal/vit-historical-page` main (v4.3, RegNetY-16GF, eleven classes, revision `543216d6b7e1`), zero-shot, the whole page squeezed to 384 px with ImageNet normalisation (the reading W46.fix-marks-set chose on the 144). "Ours" is the Processor's page-kind classifier (`kind-classifier.md`): Vision signals and the Vision feature print with a logistic regression. Page images and per-page labels stay in the private cache. No money.

## 1. The hand on the 144 owner-set pages

The 141 typed, printed and handwritten pages of the 144 (the 3 mixed pages are left out: they use the old mixed definition, KND-2). These labels were partly made by a session looking at contact sheets, not blind (KND-1), and the shipped weights were fitted on them; the learned rows are scored leave-one-folder-out. Interval: Wilson 95%.

| method | right | handwritten | typewritten | printed | said mixed | said no hand |
|---|---:|---:|---:|---:|---:|---:|
| ATRIUM zero-shot, its top class | 89/141 (55–71%) | 28/34 | 41/72 | 20/35 | 29 | 11 |
| ATRIUM zero-shot, hand-only (top of its six text classes) | 121/141 (79–91%) | 34/34 | 56/72 | 31/35 | 0 | 0 |
| Shipped classifier: Vision signals + feature print, LR (leave-one-folder-out) | 137/141 (93–99%) | 33/34 | 70/72 | 34/35 | 0 | 0 |
| ATRIUM embedding + LR head (leave-one-folder-out) | 128/141 (85–95%) | 34/34 | 66/72 | 28/35 | 0 | 0 |
| Both feature sets + LR head (leave-one-folder-out) | 134/141 (90–98%) | 34/34 | 68/72 | 32/35 | 0 | 0 |

Paired against ours (exact McNemar): hand-only ATRIUM right where ours is wrong on 3 pages, the reverse on 19 (p 0.000855); the ATRIUM head 3 against 12 (p 0.0352).

Hand-only ATRIUM's confusions:

| truth \ said | handwritten | typewritten | printed | right |
|---|---:|---:|---:|---:|
| handwritten | 34 | 0 | 0 | 34/34 |
| typewritten | 2 | 56 | 14 | 56/72 |
| printed | 2 | 2 | 31 | 31/35 |

ATRIUM's top class on the 141: TEXT_T 34, TEXT 29, TEXT_P 24, TEXT_HW 17, LINE_HW 12, DRAW 11, LINE_T 9, LINE_P 5.

## 2. Forms and tables on the 144

14 of the 144 are mainly a table or a form. ATRIUM's LINE_* classes are its "text in a table or form".

| method | right | forms found | false calls |
|---|---:|---:|---:|
| ATRIUM zero-shot, top class LINE_* | 129/144 | 13/14 | 14 |
| ATRIUM zero-shot, hand-only top class LINE_* | 120/144 | 14/14 | 24 |
| Shipped classifier, LR (leave-one-folder-out) | 141/144 | 13/14 | 2 |
| ATRIUM embedding + LR head (leave-one-folder-out) | 136/144 | 10/14 | 4 |
## 3. The 96: the hand, and what routing by each costs

The guide's first pick per kind (handwritten → gemini3.8-flash, printed → claude-sonnet5.5, forms → qwen3.6-27b, typewritten → gemini3.8-flash; no low-resolution flag, as the shipped classifier), on the 96 truth pages. "Lost" is mean NES below routing by the labels; the interval is a paired bootstrap over pages (2,000 draws). A mixed page in the labels (2) goes to the handwritten pick, as the shipped classifier sends it.

| classifier | hand right | routed as labelled | mean NES | lost | 95% interval |
|---|---:|---:|---:|---:|---:|
| Labels for hand and form | 96/96 | 96/96 | 97.23 | +0.00 | +0.00 to +0.00 |
| Shipped classifier (hand and form LR, leave-one-folder-out) | 91/96 | 92/96 | 96.23 | +1.00 | -0.02 to +3.04 |
| ATRIUM zero-shot hand-only, LINE_* for form | 79/96 | 77/96 | 96.05 | +1.18 | +0.03 to +3.32 |
| ATRIUM zero-shot top class (mixed or no hand to the handwritten pick) | 55/96 | 75/96 | 94.28 | +2.95 | +0.13 to +6.61 |
| ATRIUM embedding heads (leave-one-folder-out) | 85/96 | 86/96 | 96.15 | +1.08 | +0.01 to +3.17 |
## 4. The 895 public pages

Kind truth is the stratum's: each public set is one kind (typed L3; printed L8, L9 newspapers, N5, N6; handwritten the rest, the L4 ledgers counted as handwritten forms). Nothing here was fitted on these pages: the head and the shipped weights were fitted on the owner's 144. Non-Latin scripts (N1–N6) are outside what either was fitted on.

| method | right | handwritten (640) | typewritten (80) | printed (175) | said mixed | said no hand |
|---|---:|---:|---:|---:|---:|---:|
| ATRIUM zero-shot, its top class | 494/895 (52–58%) | 447 | 34 | 13 | 201 | 130 |
| ATRIUM zero-shot, hand-only | 638/895 (68–74%) | 509 | 72 | 57 | 0 | 0 |
| ATRIUM embedding + LR head fitted on the 141 | 625/895 (67–73%) | 478 | 77 | 70 | 0 | 0 |
| Shipped classifier (bundled weights) | 723/895 (78–83%) | 530 | 68 | 125 | 0 | 0 |

By stratum, right of pages:

| stratum | kind | pages | ATRIUM zero-shot, its top class | ATRIUM zero-shot, hand-only | ATRIUM embedding + LR head fitted on the 141 | Shipped classifier (bundled weights) |
|---|---|---:|---:|---:|---:|---:|
| L1 | handwritten | 80 | 75 | 78 | 78 | 79 |
| L2 | handwritten | 80 | 77 | 80 | 80 | 80 |
| L3 | typed | 80 | 34 | 72 | 77 | 68 |
| L4 | ledger | 80 | 80 | 80 | 80 | 80 |
| L5 | handwritten | 80 | 13 | 24 | 22 | 21 |
| L6 | handwritten | 80 | 80 | 80 | 80 | 80 |
| L7 | handwritten | 80 | 0 | 35 | 7 | 63 |
| L8 | print | 80 | 3 | 22 | 21 | 59 |
| L9 | newspaper | 15 | 5 | 14 | 15 | 15 |
| N1 | handwritten | 40 | 35 | 40 | 39 | 40 |
| N2 | handwritten | 40 | 40 | 40 | 40 | 40 |
| N3 | handwritten | 40 | 40 | 40 | 40 | 40 |
| N4 | handwritten | 40 | 7 | 12 | 12 | 7 |
| N5 | print | 40 | 5 | 21 | 33 | 37 |
| N6 | print | 40 | 0 | 0 | 1 | 14 |

Forms: hand-only ATRIUM calls LINE_* on 80 of the 80 L4 ledger pages and on 126 other pages (some of which may really hold a table: the strata carry no form label).

## 5. Mixed pages on the 2,000, against the owner's 170 answers

The owner's cut (mixed-def-score.md): any handwriting on a typed or printed page, a signature included. Of the sheet's 170 pages, 170 carry text and have an answer (121 mixed under the cut). "On the sheet" counts those pages as drawn, which is not a random draw. "Estimated in the 2,000" weights each answered page by the stratum it stands for (the disagreements by pattern; the top-up of pages both mixed classes call mixed is left out, as in the share estimate; the 14 unsettled and 105 agreed-handwritten pages are not sampled and add nothing), with a stratified bootstrap interval (2,000 draws). Recall is of the owner's mixed pages, precision of the label's mixed calls.

| label | on the sheet: found | false | AUC of p(TEXT) | est. recall | est. precision |
|---|---:|---:|---:|---:|---:|
| ATRIUM TEXT (its top class) | 103/121 | 26/49 | 0.74 | 60% (44–82) | 70% (60–79) |
| Qwen3.6-27B mixed (saved bulk label) | 66/121 | 1/49 | – | 23% (15–35) | 99% (98–100) |
| Shipped classifier handwritten | 46/121 | 6/49 | – | 12% (8–20) | 79% (59–97) |

ATRIUM's TEXT calls by how much handwriting the owner saw (called / pages): none 24/46, signature 20/22, few 62/73, passage 13/15, long 8/11, handpage 2/3.

ATRIUM says TEXT on 563 of the 2,000 (28.1%); the owner's cut puts the share near 33% (about 27–46%, KND-3). This rerun gives the same top class as W46.fix-marks-set's on 2000 of 2000 pages.

ATRIUM's hand against the shipped classifier's on the 2,000 (no truth; rows ATRIUM, columns ours):

| ATRIUM \ ours | typewritten | printed | handwritten |
|---|---:|---:|---:|
| typewritten | 714 | 27 | 6 |
| printed | 125 | 148 | 0 |
| handwritten | 2 | 11 | 126 |
| mixed | 363 | 146 | 54 |
| none | 25 | 218 | 35 |

## 6. ATRIUM's confidence and whether it is right

Hand-only reading, its probability renormalised over the six text classes; the 141 and the 895 together.

| confidence | pages | right |
|---|---:|---:|
| 0.00–0.50 | 56 | 21/56 (26–51%) |
| 0.50–0.80 | 155 | 74/155 (40–56%) |
| 0.80–0.95 | 130 | 72/130 (47–64%) |
| 0.95–1.00 | 695 | 592/695 (82–88%) |

## 7. Seconds and memory on the M3 Pro (18 GB)

One process on mps, batches of 16, torch 2.15.0; model load 1.8 s. Peak resident memory of the process 1.48 GB, MPS driver 4.8 GB at the end. Run under the heavy lock, nothing else running.

| pages | count | s a page, all in | model s a page (median batch) | JPEG decode and resize s a page |
|---|---:|---:|---:|---:|
| the 144 | 144 | 0.076 | 0.032 | 0.030 |
| the 895 | 895 | 0.110 | 0.032 | 0.077 |
| the 2,000 | 2000 | 0.063 | 0.032 | 0.032 |

The shipped classifier, for comparison: about 0.6 s a page (Vision text lines, document request and feature print; `kind-classifier.md` §5), with no download. ATRIUM's weights are a 323 MB download (CC BY-NC). Vision signals for the shipped classifier on the 895 took 538 s (0.60 s a page). The 2,895-page pass took minutes on the Mac, so it needs no cluster.

## Measurement card

- **Truth:** the 144: `kind-classifier.md`'s labels, the 99 truth pages' kinds as the drafting models and the owner left them and the drawn pages labelled by a session looking at contact sheets, not blind (KND-1); the shipped weights were fitted on them, so its rows are leave-one-folder-out. The 895: the public set's stratum kind, made by its datasets, not by any scored route; not checked page by page, and a stratum can hold a page of another kind. The 2,000: the owner's own 170 blind sheet answers (2026-10-22), read under his cut; no model's label is truth.
- **Selection:** the 144 and the 96 as `kind-classifier.md` drew them; the 895 frozen at W43.corpus-build by source and script; the 170 drawn by `mixed_def.py` from the four labels' disagreements, ATRIUM's among them, which is why the sheet figures are a check and the estimate re-weights them by stratum. No page was chosen by ATRIUM's output alone or by ABBYY text.
- **Comparison:** every method on the same images; ATRIUM at one preprocessing (chosen on the 144 by W46.fix-marks-set, which flatters it there slightly); the heads with the same regression, penalty and folders as the shipped classifier's.
- **Noise:** Wilson 95% intervals on rates, exact McNemar on paired right/wrong, paired bootstrap on NES lost, stratified bootstrap on the 2,000's estimates. ATRIUM is deterministic here: the rerun gives the same top class as W46.fix-marks-set's on 2000 of 2000 pages.
- **Scope:** page kind for routing only. It does not settle where on a page the handwriting is (W46.marks-detect), how mixed pages should be read (W46.mixed-route), or ATRIUM on other corpora; the 144 has few forms (14) and the 895's form truth is the ledger stratum alone.

