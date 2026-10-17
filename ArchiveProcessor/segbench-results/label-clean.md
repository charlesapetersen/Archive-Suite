# W41.seg-label-clean — the tag-implied labels cleaned by Qwen3.5 27B

The training windows of `corpus-pairs.md` (16,443 seven-page windows at stride 3 over 113,933 pages, 117
per-document folders) were sent to Qwen3.5 27B on FarmShare as the teacher: `fs_seg.py`, preset fs-qwen3.5-27b,
1,024 px, prompt o1, max_tokens 1,500, four shards of about 4,111 windows on one L40S each (Slurm jobs
1850803-1850806, 2026-10-16). `corpus_pairs.py clean` then gave every gap the teacher's P(new), averaged over
the windows that cover it, and labelled it under two rules. No money: GPU time on Stanford's cluster.

Numbers only: no names, text or images. The teacher's answers (`answers.jsonl`, 25 MB) are kept outside git at
`~/Library/Application Support/ArchiveSuiteRehearsal/label-clean/clean-all/`; the labels it produced
(`labels.jsonl`, `labels-summary.json`) are in the corpus-pairs cache. Rerunning `clean` on that copy reproduces
the summary exactly.

**16,429 of 16,443 windows answered; 14 failed. Every one of the 48,748 gaps was judged by at least one window**,
since stride 3 covers each gap twice, so the failures were not resubmitted.

## The two rules

- **agree**: a gap keeps its tag label only where the teacher's P(new) is on the tag's side of 0.5; otherwise it
  is dropped.
- **start-trust** (the owner's reading, 2026-10-16: a tag change almost always marks a real start, but he sometimes
  kept separate documents on nearby dates under one tag set): a tag start stands unless the teacher is sure it is
  a continuation (P(new) ≤ 0.15); a tag continuation becomes a start where the teacher is sure of one
  (P(new) ≥ 0.85), stays a continuation below 0.5, and is dropped between.

## How many labels survive

| split | tag | gaps | agree keeps | share | start-trust: start | continuation | dropped |
|---|---|---:|---:|---:|---:|---:|---:|
| train | start | 10,282 | 9,611 | 93.5% | 9,681 | — | 601 |
| train | continuation | 31,189 | 22,596 | 72.4% | 6,913 | 22,596 | 1,680 |
| holdout | start | 2,030 | 1,839 | 90.6% | 1,852 | — | 178 |
| holdout | continuation | 5,247 | 3,829 | 73.0% | 1,102 | 3,829 | 316 |

Agree keeps 77.7% of training gaps (32,207 of 41,471); start-trust keeps 94.5% (39,190), relabelling 6,913 of them.
A window can train whole only when all six of its gaps keep a label:

| split | windows | whole under agree | whole under start-trust |
|---|---:|---:|---:|
| train | 13,984 | 5,889 (42.1%) | 11,105 (79.4%) |
| holdout | 2,459 | 934 (38.0%) | 1,821 (74.1%) |

The teacher calls 27.6% of tag continuations starts, three and a half times the 7.9% of continuations the owner found wrong
in the 2026-10-08 sample (`corpus-survey.md`). So most of what agree drops on that side are probably right labels
lost to the teacher's false splits, which is also the error the untrained 4B makes most. Start-trust does the
opposite with the confident ones and turns 8,015 continuations into starts. Whether those flips are mostly
right is the open question, and the next section cannot answer it.

## Against the owner's 2026-10-08 sample

69 of that sample's 80 gaps are in the run with a clear answer (11 were not among the run's gaps or were
marked unsure). The tags are right on 61 and wrong on 8.

| labels | right | wrong | dropped | noise among kept |
|---|---:|---:|---:|---:|
| tags alone | 61 | 8 | — | 11.6% |
| agree | 56 | 1 | 12 | 1.8% |
| start-trust | 57 | 3 | 9 | 5.0% |

Agree removes 7 of the 8 wrong tags and loses 5 right ones. This sample is not independent evidence: it is what
the rules were read against while they were being designed, and it holds only 3 gaps of the kind start-trust
relabels (2 of them wrong). Measuring the noise that is left takes a fresh sample (below).

## A fresh owner check

`corpus_pairs.py checkpack` draws 80 kept gaps, none from the 2026-10-08 sample, in four strata by how
start-trust kept them, and builds a blind page in the cache (`corpus-pairs/checkpack/index.html`):

| stratum | what it is | gaps in the run | drawn | kept by |
|---|---|---:|---:|---|
| A | tag start, teacher agrees | 11,421 | 25 | both rules |
| B | tag start, teacher leans continuation (0.15 < P < 0.5) | 83 | 5 | start-trust |
| C | tag continuation, teacher sure of a start | 8,011 | 25 | start-trust (as a start) |
| D | tag continuation, teacher agrees | 26,395 | 25 | both rules |

(The populations here leave out the old sample's gaps and the few gaps whose photos have no JPEG.)
`corpus_pairs.py checkscore <answers>` scores the owner's answers: per stratum, then each rule's noise among the
labels it keeps, weighted by stratum size. Follow-up `W41.seg-label-clean-fu1`.
