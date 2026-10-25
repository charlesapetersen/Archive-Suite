# The owner's mixed-page definition

W46.fix-marks-set-draft prerequisite, scored 2026-10-25 with
`scripts/segbench/mixed_def.py score`; machine-readable output: `mixed-def-score.json`.
The owner answered all 170 pages on 2026-10-22. No new model inference or spending.

The supported cut is **any handwriting on a typed or printed page, including a
signature or initials**. Of the 121 sampled pages with handwriting on print, the
owner called 119 mixed:

| Handwriting on print | Called mixed | Answered |
|---|---:|---:|
| Signature, initials or handwritten date only | 21 | 22 |
| Under about 10 words | 72 | 73 |
| About 10–29 words | 15 | 15 |
| 30 words or more | 11 | 11 |

The other 49 pages were 46 without handwriting and 3 handwritten pages; no
mixed verdict was asked for those. The two explicit negative verdicts remain
in the private answers. The threshold is a sampling/label-definition rule,
not permission to overwrite those answers or discard signatures from OCR.

## Estimated share of the bulk-pilot draw

At that cut, the existing scorer's post-stratified estimate is **33.02%**, about
660 of the 2,000 bulk-pilot pages. This is an estimate, not 660 individually
checked pages and not the proportion in the deliberately enriched 170-page sheet.
The earlier Qwen mixed label (8.25%) used another definition; it is a candidate
signal, not a complete filter for this set.

| Population stratum | Pages in draw | Checked for estimate | Threshold-positive rate |
|---|---:|---:|---:|
| Classifiers disagree | 630 | 100 | 68.4%, weighted by disagreement pattern |
| All mixed | 39 | 39 | 97.4% |
| Agreed typed/printed controls | 1,212 | 20 | 15.0% |
| Consistent but unsettled | 14 | 0 | Assumed disagreement rate |
| Agreed handwritten page | 105 | 0 | Assumed not mixed |

The eleven all-mixed top-up pages inform the definition but are excluded from
the population estimate to avoid counting disagreements twice. Three of only
20 agreed-clean controls carry handwriting; their large population weight
makes the estimate uncertain. No confidence interval is calculated by this
scorer. Treat 33.02% as a descriptive point estimate of the existing draw,
with explicit unsampled-stratum assumptions, not a precise corpus-wide rate.

## Input receipts

Private cache: `~/Library/Caches/ArchiveSuiteRehearsal/mixed-def/`. There are
2,000 distinct label IDs and a cached JPEG for every ID. No source collection
or original-JPEG path is present in `labels.tsv` or the sheet key; this score
does not establish image provenance for a new marks benchmark.

| Input | SHA-256 |
|---|---|
| `labels.tsv` | `1d556aa55d4c353f91834daf8cf3b4f66a97fb9a45c30cd8858bcd523fafc1b4` |
| `sheet/answers.json` | `f8b7fef890c09ff407c087d823639a1457782643e571c88aa90f17522d8d95fb` |
| `sheet/key.json` | `06a1c793f2ffa71d197a142d1a60a4dc83950c056c3c65430ca14e0d253d7b61` |

Verification: 20 `test_mixed_def.py` tests pass; the live answer totals and
threshold calculation were checked separately against the saved inputs.
Images, per-page answers, source paths and transcripts are not published.
