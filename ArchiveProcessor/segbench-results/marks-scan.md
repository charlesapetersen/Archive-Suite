# Marks pre-flag scan: 1,014 pages, and the 150-page draw it feeds

W46.fix-marks-set-draft, 2026-10-31. The owner's Sherlock batch 20261030-075422 ran the frozen scan
(`marks-scan-20261029`, freeze `1a21f581…`) and it was fetched into the private artifact of the same name.
Figures are from `marks_scan.py summary`, which checks every receipt against the freeze and its intent.

| | |
|---|---|
| Reader | Qwen3.6-27B-FP8, vLLM 0.31.0, one request at a time, the v2 prompt (owner bands) |
| Pages | 1,014 sent, 1,014 read (`complete: true`); 1,013 valid, 1 parse failure (Stanton) |
| Replies in a json fence (removed, recorded) | 7 |
| Band inconsistent with the mark flags (kept) | 24 |
| `uncertain` | 2 |
| Requests | 7,588 s, median 7.43 s a page (the pilot's 5.16 s was on shorter replies) |
| Slurm | CPU stage 1 min 18 s; GPU job 2 h 16 min with model load, inside the 3 h reservation |
| GPU-hours | about 2.3, against the size review's estimate of 1.5 |

## Pre-flag by collection and band (pages)

| Collection | Read | Any mark | None | Sig/initials/date | Under 10 words | 10-29 | 30+ | Handwritten page |
|---|---|---|---|---|---|---|---|---|
| Dean | 225 | 130 | 106 | 20 | 74 | 12 | 10 | 3 |
| Deaver | 225 | 114 | 119 | 24 | 82 | 0 | 0 | 0 |
| Herrnstein | 225 | 117 | 110 | 44 | 50 | 6 | 5 | 10 |
| Stanton | 224 | 76 | 148 | 56 | 15 | 0 | 0 | 5 |
| RG165 | 114 | 38 | 78 | 4 | 19 | 11 | 1 | 1 |
| **All** | **1,013** | **475** | **561** | **148** | **240** | **29** | **16** | **19** |

Classes flagged (a page can carry several): annotation 365, signature or initials 155, marginal note 89, stamp 42,
other 13, redaction 13; a mark overlapping print on 175. Handwriting of some kind on 450 pages, 432 of them typed or
printed pages. Page kind: typed or printed 978, handwritten 20, non-text 15.

These are a candidate signal, not marks truth. The flagged share (47%, handwriting on 43% of typed pages) sits above
the owner's post-stratified 33% for "any handwriting" on the bulk pages (`mixed-def-score.md`); the frames differ
(these are original JPEGs from five collections, those the 2,000 bulk pages) and the pilot's false flags
(show-through, printed signatures, overstrikes) are named in the prompt but not proved gone. The upper bands came out
thinner than the size review assumed (29 and 16 pages, against 30-40 each), and Deaver and Stanton have none in
either, so W46.mixed-route-bands' upper bands come from Dean, Herrnstein and RG165.

## The 150-page draw (`marks_set.py select`, `marks-set-selection.json`)

Drawn so the set is not chosen only by the pre-flagger, which W46.marks-detect will rank (measurement audit MRK-1):

- **Phase A, 50 pages, flag-independent.** Uniform within each collection in a fixed seed order: 11 each from Dean,
  Deaver, Herrnstein and Stanton, 6 from RG165 (about 50 × N/1,014). 24 of the 50 happen to be pre-flagged. Each
  page's phase-A fraction is exact (11/225, 6/114), but only the 16 of them in the owner core get owner truth; the
  other 34 are drafts, not recall observations (measurement review 2026-10-31 pass 3, P3-3).
- **Phase B, 100 pages, enriched.** From the remaining 964: every remaining 30+ (15) and 10-29 (27) page; 4
  handwritten pages; 4 a collection from the signature band (20) and from the under-10 band (20); the 14 left over
  from the no-mark band, spread across the collections. Its probabilities are conditional on phase A (the stratum's
  remaining count); `phase_membership_approx` = pA + (1 − pA) · pB approximates phase membership only.
- **The owner core, 40 pages**: 16 of phase A's 50 in seed order (10 unflagged, 6 flagged) and 24 from phase B by
  band (6 of 30+, 6 of 10-29, 4 signature, 4 under-10, 1 handwritten page, 3 no-mark), taking the lowest seed ranks
  again and pooling collections. Each core page records its conditional fraction; none of these fractions is a
  validated final core inclusion weight (W46.marks-sampling-support), so core results are descriptive of an enriched
  set, A-core 16 and B-core 24 reported apart, and never weighted to population recall, a mixed share or a
  corpus-weighted routing benefit (the selection JSON's `weighting` block).
- By collection: Dean 44, Herrnstein 33, RG165 28, Stanton 23, Deaver 22.

## Measurement card

- **Truth.** None here. The pre-flag is one model's reading; nothing in this report is a mark label. The owner's
  core check (W46.marks-core-owner-ok) is the first truth the set gets.
- **Selection.** Phase A is independent of every tested route. Phase B is chosen by the pre-flagger's band, so its
  pages may not be used to estimate the pre-flagger's recall or the mixed share. Phase A is flag-independent, but its
  owner-checked part (A-core 16) has no validated weight either; the mixed share and its interval stay
  mixed-def-score's independent measurement.
- **Comparison.** Not applicable: one reader, one prompt, one pass.
- **Noise.** One pass at temperature 0; no rerun floor was measured. The band counts are single-reading counts.
- **Scope.** Does not say how often the pre-flag is right, how many marks a page carries, or where they are. Does not
  settle the mixed share (that is the owner's figure with its interval).
