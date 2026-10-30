# W46.seg-truth-sheet — one blind owner sheet for the doubted segmentation truth

Written by hand from `seg_truth_sheet.py sheet` (numbers only: no names, text or images). The measurement audit of
2026-10-30 (`execution-plans/processing-review/11-measurement-audit.md`, SEG-1, SEG-2, SEG-3, SEG-7) found three test
truths no owner has ruled where it matters. This sheet asks those gaps in one sitting, about 30 minutes. It is built
from cached data with no model calls, paid or plan; no Claude reader looked at the pages to choose them. The sheet, its
key and the thumbnails are in `~/Library/Caches/ArchiveSuiteRehearsal/seg-truth-sheet/`, outside git.

| section | finding | gaps asked | where they come from |
|---|---|---:|---|
| Stanton, one newsletter issue | SEG-7 | 4 | photos 101-105 (cover at 101), the run under case 38 (photo 102) kept whole by the full-magazine rule; each case shows the cover first |
| CIA CREST | SEG-2 | 6 | right photos 46, 88, 94, 111 (the audit's ambiguous continuations) and 75, 95 (the separately preserved briefing copies) |
| Lincoln Papers | SEG-3 | 5 | right photos 76, 230 (clippings), 77, 231 (the ambiguous wrappers) and 107 (a mailed envelope kept with its letter) |
| SC0122 News Service | SEG-1 | 60 | a stratified draw from the 162 gaps where tag and teacher agreed (below) |
| **all** | | **75** | |

**Other magazine runs.** A masthead screen of the five original boxes' cached Apple Vision text (an issue number,
"Vol. N, No.", or "Published by/monthly/quarterly/weekly") found one multi-page issue: Stanton 101-105. Its other hits
were the words "magazine" or "newsletter" inside letters or one- and two-page clippings, which the 2026-10-05 truth
check already ruled and which the article rule leaves as they are (an article is its own document either way). So the
magazine run covers 5 of Stanton's 250 pages, 4 of its gaps.

**The SC0122 draw** (seed 20261030). The agreed gaps are split by the W41.seg-label-clean teacher's mean P(new); the
less certain strata are drawn more heavily, since a teacher error is likelier there, and `fold` weights each control
by its stratum's N/n so the error rate is an estimate for all 162:

| stratum | N (agreed gaps) | n (drawn) | weight N/n |
|---|---:|---:|---:|
| tag cont, P(new) < 0.02 | 35 | 12 | 2.92 |
| tag cont, 0.02 ≤ P(new) < 0.5 | 60 | 24 | 2.50 |
| tag new, 0.5 ≤ P(new) < 0.99 | 12 | 12 | 1.00 |
| tag new, P(new) ≥ 0.99 | 55 | 12 | 4.58 |

**Answers.** Stanton offers new, continues, fallback (keep with the whole issue) and can't tell; CREST and Lincoln
add "belongs to an earlier document" for a wrapper separated from its letter; SC0122 offers a label card as its own
sheet did. `seg_truth_sheet.py fold FILE` writes `rulings.json` in the cache with each answer beside the current truth,
and prints per-section agreement and SC0122's weighted error on the agreed stratum. W46.seg-truth-rescore takes it from
there (the rescore of every cached answer on Stanton, CREST and Lincoln).

Nine SC0122 thumbnails matched their corpus PDF weakly (correlation under 0.65: photos 62, 73, 77, 113, 124, 184,
185, 189, 191), as eight did on the box's own sheet; a sideways photo costs a turn of the head, not a wrong ruling.

## Measurement card

- **Truth:** none is scored here. The sheet asks the owner for truth on 75 gaps whose current labels came from the
  full-magazine rule (Stanton), one Codex agent's audit (CREST, Lincoln), or tag and teacher agreement (SC0122).
- **Selection:** Stanton by the owner's case 38 and a masthead screen of OCR text; CREST and Lincoln by the agent's own
  ambiguous and borderline notes in the frozen manifests; SC0122 by a seeded draw stratified on the teacher's P(new).
  No tested route's answers and no ABBYY text chose a case.
- **Comparison:** not applicable until the answers are folded; W46.seg-truth-rescore rescores every cached answer on
  the same truth.
- **Noise:** the SC0122 estimate rests on 60 controls; with 5.3% label noise expected (the checkpack's agree rule) it
  will carry a wide interval, which `fold`'s weighted rate does not hide: report it with its n.
- **Scope:** it does not re-rule the method prompts or the app (W46.seg-magazine-rule-redo), and it does not rule
  CREST or Lincoln gaps the agent did not mark.
