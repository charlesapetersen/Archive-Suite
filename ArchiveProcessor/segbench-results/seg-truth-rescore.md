# W46.seg-truth-rescore — the owner's segmentation sheet folded in, every cached answer rescored

The owner answered the W46.seg-truth-sheet sheet on 2026-10-31: all 75 gaps (`seg-truth-sheet.md`). This item folds
his rulings into the truth and rescores every cached answer on Stanton, CREST and Lincoln. No model was run: every
step read its own response cache under `rescore.no_network()`, so a hole would have stopped it, and none did. $0.
The tables below are `seg_truth_rescore.py report` (before = the results committed just before the fold); the
rulings, numbers only, are `seg-truth-rulings.json`.

## What was folded

| box | gap | agent's or rule's truth | owner | now |
|---|---|---|---|---|
| Stanton | 101\|102, 102\|103 | Cont (full-magazine rule) | new | New: the newsletter issue's articles split |
| Stanton | 103\|104, 104\|105 | Cont | same | unchanged |
| CREST | 74\|75 | New (a separately preserved copy of the briefing) | same | Cont |
| CREST | 94\|95 | New | new | unchanged |
| CREST | 45\|46, 87\|88, 93\|94, 110\|111 | Cont | can't tell | unsure |
| Lincoln | 75\|76 | New | new | unchanged |
| Lincoln | 229\|230 | New (an enclosed printed proceedings) | same | Cont |
| Lincoln | 76\|77, 106\|107, 230\|231 | New, Cont, New | can't tell | unsure |
| SC0122 | 60 agreed controls | tag and teacher agreed | 60 agree | recorded in lock.json as owner-ruled |

Where the files are: the Stanton truth CSV in `Test Files` (outside git; the pre-fold copy is
`seg-truth-sheet/stanton-truth-before-fold.csv` in the cache), the `label` and `audit` of the two public manifests
plus their new `unsure` and `owner_rulings` fields, and SC0122's `lock.json` (`owner_ruled_controls`; opened for the
one write and locked again, `seg_boxes.py verify sc0122`: intact).

**Superseded in part (W46.seg-report-refresh, 2026-10-31).** As written here, an unsure gap took the route's own call and
so still counted as an agreement in the boundary counts (gaps, true boundaries, boundary F1, kappa); W46.seg-unsure-mask
then took unsure gaps out of every boundary count and out of the review load. The boundary F1 and kappa figures below
for CREST and Lincoln therefore read slightly high; pages exact, false splits and merges are unchanged. The current
figures are in the regenerated reports (`public-segmentation/*-scores.json`, `seg-scorers.md`, `seg-lincoln-cloud.md`,
`seg-lincoln-gateway.md`, `seg-kit-gate.md`). This record of the fold is kept as written.

**Unsure gaps** (the owner's call: excluded from every score). `score_labels` gives an unsure gap the route's own
call before scoring (`score.forgive`, carried by `Collection.labels` as a `score.Truth`), so it is never an error
under any metric, and the flag-and-check scorers (`ensemble`, `seg_adapt_curve`, `seg_adapt_fewshot`) leave it out
of their held-out and accepted error counts. One consequence: on CREST and Lincoln the truth's document count now
follows each route at those seven gaps (CREST 30 to 34 documents, Lincoln 78 to 81), so `pages exact` there is
"exact, given the route's reading of the gaps nobody can rule".

## SC0122: the 60 controls (R-11)

The owner agreed with the tag-and-teacher truth on all 60 controls drawn from its 162 agreed gaps.

| estimate | errors | n | rate | 95% Wilson interval |
|---|---:|---:|---:|---|
| unweighted, over the controls | 0 | 60 | 0.0% | 0.0-6.0% |
| weighted by N/n to all 162 agreed gaps | 0 | 50.8 (Kish's effective n of the 60) | 0.0% | 0.0-7.0% |

So SC0122's agreed stratum carries no measured label error, and at most about 7% of it (about 11 of 162 gaps) could
be wrong at 95%. The checkpack's 5.3% (W46.kit-gate) sits inside that interval: the controls do not show the agreed
stratum is cleaner than the checkpack, only that it is not worse.

## Stanton: what the 4 gaps moved

Two of the four Stanton gaps changed (101|102, 102|103: one issue of the newsletter becomes three documents); the
other two kept their label. Every test-box figure that includes Stanton moved by about 2 points on Stanton, 1.5
pooled, and in a direction set by how the route read the issue: a route that kept the issue whole (most cloud
routes, the 27B teacher) loses; one that split it (the fine-tuned 2B and 4B, spring-v1) gains.

| approach | Stanton, no checking | Stanton, after checking | Stanton, unflagged errors | test pooled, no checking | test pooled, after checking | test pooled, unflagged errors |
|---|---:|---:|---:|---:|---:|---:|
| Claude only | 86.8% → 84.8% | 97.1% → 97.1% | 2 → 2 | 87.0% → 85.5% | 97.3% → 97.3% | 3 → 3 |
| Gemini only | 89.3% → 87.2% | 100.0% → 97.9% | 0 → 2 | 88.8% → 87.3% | 100.0% → 98.5% | 0 → 2 |
| ChatGPT only | 91.8% → 89.7% | 100.0% → 100.0% | 0 → 0 | 92.4% → 90.9% | 100.0% → 100.0% | 0 → 0 |
| Claude and ChatGPT together | 91.8% → 89.7% | 97.1% → 97.1% | 2 → 2 | 92.4% → 90.9% | 97.3% → 97.3% | 3 → 3 |
| GLM-5.3 Flash only (budget) | 81.5% → 79.4% | 97.9% → 95.9% | 1 → 3 | 82.1% → 80.6% | 98.5% → 97.0% | 1 → 3 |
| Corpus-trained Qwen3.5 2B on this Mac (no key) | 73.3% → 75.3% | 96.3% → 98.4% | 3 → 1 | 78.8% → 80.3% | 97.3% → 98.8% | 3 → 1 |

The ordering of the app's options does not change: ChatGPT and the Claude + ChatGPT mix still lead, Claude still
needs the fewest checks. What changes is the unflagged-error count at the frozen levels: Gemini only goes from 0 to
2 on the test boxes (98.5% after checking, still over the 98% bar) and GLM from 1 to 3; the local 2B from 3 to 1.
The two new errors are the issue's own gaps, which the frozen levels let through unflagged; every count here is
still within the "one or two errors is noise" note in `options.md`. The app's `options.json` carries the new
figures, and its levels and mix rule are untouched (nothing was refit).

Every cached source on Stanton (`seg-scorers-owner.json`), where a figure moved:

| source | pages exact | false splits | false merges |
|---|---:|---:|---:|
| all-new | 20.2% → 21.0% | 131 → 129 | 0 → 0 |
| no-boundaries | 0.0% → 0.0% | 0 → 0 | 107 → 109 |
| rule-cues-sketch | 19.8% → 20.6% | 130 → 128 | 1 → 1 |
| rule-cues | 29.2% → 30.0% | 81 → 79 | 14 → 14 |
| spring-baseline | 67.5% → 67.5% | 3 → 3 | 16 → 18 |
| spring-v1 | 81.1% → 83.1% | 11 → 9 | 2 → 2 |
| spring-v2 | 62.6% → 62.6% | 20 → 20 | 9 → 11 |
| window-claude | 86.8% → 84.8% | 7 → 7 | 4 → 6 |
| window-cues-codex | 91.8% → 89.7% | 2 → 2 | 3 → 5 |
| window-gemini-3.8-flash-low | 89.3% → 87.2% | 6 → 6 | 2 → 4 |
| window-or-gpt5.6-luna | 83.5% → 81.5% | 10 → 10 | 4 → 6 |
| window-or-glm5.3-flash | 81.5% → 79.4% | 6 → 6 | 6 → 8 |
| window-or-qwen3.5-flash | 76.5% → 74.5% | 12 → 12 | 4 → 6 |
| window-or-fs-qwen3.5-27b | 81.9% → 79.8% | 19 → 19 | 1 → 3 |
| window-or-fs-seg-4b | 79.0% → 80.2% | 18 → 17 | 1 → 2 |
| window-or-fs-seg-2b | 73.3% → 75.3% | 23 → 21 | 4 → 4 |
| whole-gemini | 83.1% → 81.1% | 5 → 5 | 4 → 6 |

## CREST: the ambiguous gaps resolved (SEG-2)

| route | pages exact | false splits | false merges | PQ |
|---|---:|---:|---:|---:|
| all-new | 7.0% → 10.2% | 97 → 94 | 0 → 0 | 0.113 → 0.160 |
| no-boundaries | 0.0% → 0.0% | 0 → 0 | 30 → 29 | 0.000 → 0.000 |
| rule-cues-sketch | 7.0% → 10.2% | 89 → 86 | 0 → 0 | 0.119 → 0.169 |
| rule-cues | 11.7% → 14.8% | 83 → 80 | 0 → 0 | 0.162 → 0.213 |
| fs-qwen3.5-27b | 95.3% → 88.3% | 2 → 1 | 0 → 0 | — → 0.983 |
| fs-seg-2b | 91.4% → 81.2% | 2 → 2 | 2 → 2 | — → 0.890 |
| fs-seg-4b | 98.4% → 88.3% | 1 → 1 | 0 → 0 | — → 0.982 |
| window-cues-claude | 84.4% → 89.1% | 3 → 1 | 0 → 0 | 0.913 → 0.983 |
| window-cues-claude-cue | 84.4% → 89.1% | 3 → 1 | 0 → 0 | 0.913 → 0.983 |
| gateway-gemini | 84.4% → 89.1% | 3 → 1 | 0 → 0 | 0.913 → 0.983 |
| gateway-glm | 95.3% → 88.3% | 2 → 1 | 0 → 0 | 0.930 → 0.983 |
| gateway-gemini-whole | 95.3% → 88.3% | 2 → 1 | 0 → 0 | 0.930 → 0.983 |

Each route's call at the ruled gaps (N new, c same; `seg_truth_rescore.py calls`), and where its errors now are:

| route | 45\|46 (unsure) | 74\|75 (same) | 87\|88 (unsure) | 93\|94 (unsure) | 94\|95 (new) | 110\|111 (unsure) | errors now at |
|---|---|---|---|---|---|---|---|
| fs-qwen3.5-27b | N | N | c | c | N | N | 74\|75 |
| fs-seg-2b | c | N | c | c | N | N | 1\|2, 4\|5, 20\|21, 74\|75 |
| fs-seg-4b | c | N | c | c | N | N | 74\|75 |
| window-cues-claude | N | N | N | c | N | N | 74\|75 |
| window-cues-claude-cue | N | N | N | c | N | N | 74\|75 |
| gateway-gemini | N | N | N | c | N | N | 74\|75 |
| gateway-glm | N | N | c | c | N | N | 74\|75 |
| gateway-gemini-whole | N | N | c | c | N | N | 74\|75 |

With the four gaps the owner could not rule set aside, and his ruling at 74|75, CREST no longer ranks the routes.
Before, the cloud windows (Claude, Gemini, the cue arm) scored 84.4% against the open models' 95.3-98.4%, and their
extra errors sat at 45|46 and 87|88 (the audit's ambiguous continuations). Those are now unsure. Every model route
reads 74|75, the separately preserved copy of the briefing, as a new document and the owner as the same one, and for
every route but the 2B student it is now the only error. They land at 88.3-89.1%, a tie: the spread is the truth's
document count following each route at the unsure gaps, not a difference in errors. The 2B student (81.2%; errors at
1|2, 4|5, 20|21 and 74|75) is the one route still behind. SEG-2's "cloud below open" is not reversed
either: on the owner's truth CREST cannot tell the routes apart.

## Lincoln: the ambiguous gaps resolved (SEG-3)

| route | pages exact | false splits | false merges | PQ |
|---|---:|---:|---:|---:|
| all-new | 7.3% → 6.9% | 180 → 180 | 0 → 0 | 0.111 → 0.105 |
| no-boundaries | 0.0% → 0.0% | 0 → 0 | 80 → 77 | 0.000 → 0.000 |
| rule-cues-sketch | 7.3% → 6.9% | 180 → 180 | 0 → 0 | 0.111 → 0.105 |
| rule-cues | 16.9% → 16.9% | 85 → 86 | 15 → 14 | 0.282 → 0.276 |
| fs-qwen3.5-27b | 39.5% → 40.6% | 40 → 40 | 0 → 0 | — → 0.571 |
| fs-seg-2b | 34.9% → 35.6% | 44 → 44 | 2 → 1 | — → 0.529 |
| fs-seg-4b | 46.7% → 49.8% | 32 → 31 | 2 → 0 | — → 0.669 |
| window-cues-claude | 90.0% → 90.4% | 1 → 2 | 2 → 0 | 0.956 → 0.983 |
| window-cues-claude-cue | 90.0% → 89.3% | 2 → 3 | 0 → 0 | 0.984 → 0.966 |
| gateway-gemini | 87.0% → 86.2% | 5 → 6 | 0 → 0 | 0.952 → 0.933 |
| gateway-gemini-whole | 88.1% → 87.7% | 3 → 4 | 1 → 0 | 0.956 → 0.963 |

Each route's call at the ruled gaps (N new, c same; `seg_truth_rescore.py calls`), and where its errors now are:

| route | 75\|76 (new) | 76\|77 (unsure) | 106\|107 (unsure) | 229\|230 (same) | 230\|231 (unsure) | errors now at |
|---|---|---|---|---|---|---|
| fs-qwen3.5-27b | N | N | N | N | N | 40 gaps |
| fs-seg-2b | N | N | c | c | N | 45 gaps |
| fs-seg-4b | N | N | N | c | c | 31 gaps |
| window-cues-claude | N | c | c | N | c | 229\|230, 240\|241 |
| window-cues-claude-cue | N | N | c | N | N | 86\|87, 229\|230, 240\|241 |
| gateway-gemini | N | N | c | N | N | 57\|58, 58\|59, 86\|87, 229\|230, 234\|235, 240\|241 |
| gateway-glm | not scored (ParseError) |
| gateway-gemini-whole | N | N | c | N | c | 57\|58, 130\|131, 229\|230, 240\|241 |

The drop holds, and so does the order among the cloud arms, within a gap or two. Claude's windows are at 90.4% (2
false splits, 0 merges: the two merges at the wrapper pages 77 and 231 are now unsure), the Claude cue arm 89.3%,
Gemini whole 87.7% and windows 86.2%; the open models are at 35.6-49.8% (31-45 wrong gaps each). The owner's ruling
at 229|230 (the enclosed printed proceedings is the same document as its letter) adds one false split to every cloud
arm, the same kind of gap as CREST's 74|75; the 2B and 4B students call it the same document, as the owner does. Gemini's few-shot result moves with it: zero-shot 6 held-out errors, few-shot 4 (both
include 229|230), and the few-shot arm's earlier "new false merge at 76|77" is gone, because 76|77 is unsure.

## seg-context and seg-window-modality

The collection-facts block and the window-modality verdicts were read against noise; the rescore moves both arms of
each comparison together. On CREST the block's effect is unchanged (teacher 88.3% in both arms; student 71.9% without, 81.2% with,
the same 9-point gap as before, which `seg-context.md` reported as one vote). On Lincoln the teacher's gain from the
block grows from +3.0 to +5.0 points; on Stanton its sign turns (-2.1 to +1.2 points). `seg-context.md` judged both
boxes by vote flips against a plain rerun's (Lincoln 22 against 6, Stanton 5 against 2), which the truth does not
change, so its verdict stands. Window size and images: arms move by up to 3.1 points, most of them up on Lincoln and
on Stanton for the 2B, in both directions for the 4B and the teacher on Stanton; the pooled verdicts in
`seg-window-modality.md` rest on the development and test pools, where Stanton is one of five boxes.

seg-context.json, where a row moved:

| model | box | arm | pages exact | boundary F1 |
|---|---|---|---:|---:|
| teacher | CREST | base | 95.3% → 88.3% | 0.968 → 0.984 |
| teacher | CREST | block | 95.3% → 88.3% | 0.968 → 0.984 |
| teacher | Lincoln | base | 34.9% → 36.0% | 0.792 → 0.792 |
| teacher | Lincoln | block | 37.9% → 41.0% | 0.790 → 0.804 |
| teacher | Stanton | base | 81.9% → 79.8% | 0.914 → 0.906 |
| teacher | Stanton | block | 79.8% → 81.1% | 0.910 → 0.911 |
| student | CREST | base | 82.0% → 71.9% | 0.918 → 0.918 |
| student | CREST | block | 91.4% → 81.2% | 0.933 → 0.933 |
| student | Lincoln | base | 32.2% → 33.0% | 0.765 → 0.768 |
| student | Lincoln | block | 35.6% → 36.4% | 0.772 → 0.776 |
| student | Stanton | base | 74.1% → 76.1% | 0.900 → 0.909 |
| student | Stanton | block | 74.1% → 76.1% | 0.888 → 0.897 |

seg-window-modality.json, where a row moved:

| model | box | arm | pages exact | boundary F1 |
|---|---|---|---:|---:|
| 2b | Lincoln | o0-l1 | 36.4% → 37.2% | 0.766 → 0.770 |
| 2b | Lincoln | o0-w1 | 42.1% → 43.3% | 0.791 → 0.800 |
| 2b | Lincoln | o1-l1 | 31.0% → 33.7% | 0.760 → 0.769 |
| 2b | Lincoln | o1-w1 | 48.7% → 51.3% | 0.804 → 0.814 |
| 2b | Lincoln | o2-l1 | 33.3% → 34.5% | 0.768 → 0.778 |
| 2b | Lincoln | o2-w1 | 49.0% → 49.8% | 0.802 → 0.806 |
| 2b | Lincoln | mean-of-singles | 40.1% → 41.6% | 0.782 → 0.790 |
| 2b | Lincoln | vote6 | 47.5% → 48.3% | 0.786 → 0.790 |
| 2b | Lincoln | vote-offsets-l1 | 34.5% → 37.2% | 0.765 → 0.775 |
| 2b | Lincoln | vote-prompts-o0 | 45.2% → 46.4% | 0.781 → 0.789 |
| 2b | Stanton | o0-l1 | 76.5% → 78.6% | 0.913 → 0.922 |
| 2b | Stanton | o0-w1 | 74.9% → 77.0% | 0.903 → 0.912 |
| 2b | Stanton | o1-l1 | 73.3% → 75.3% | 0.897 → 0.907 |
| 2b | Stanton | o1-w1 | 76.1% → 78.2% | 0.896 → 0.905 |
| 2b | Stanton | o2-l1 | 71.6% → 73.7% | 0.888 → 0.897 |
| 2b | Stanton | o2-w1 | 74.1% → 76.1% | 0.895 → 0.904 |
| 2b | Stanton | mean-of-singles | 74.4% → 76.5% | 0.899 → 0.908 |
| 2b | Stanton | vote6 | 78.2% → 80.2% | 0.912 → 0.922 |
| 2b | Stanton | vote-offsets-l1 | 73.3% → 75.3% | 0.905 → 0.915 |
| 2b | Stanton | vote-prompts-o0 | 74.9% → 77.0% | 0.903 → 0.912 |
| 4b | Lincoln | o0-l1 | 49.4% → 52.5% | 0.825 → 0.840 |
| 4b | Lincoln | o0-w1 | 48.3% → 51.0% | 0.832 → 0.842 |
| 4b | Lincoln | o1-l1 | 51.3% → 50.6% | 0.827 → 0.821 |
| 4b | Lincoln | o1-w1 | 45.6% → 46.4% | 0.823 → 0.827 |
| 4b | Lincoln | o2-l1 | 48.7% → 49.8% | 0.812 → 0.812 |
| 4b | Lincoln | o2-w1 | 46.0% → 47.1% | 0.821 → 0.821 |
| 4b | Lincoln | mean-of-singles | 48.2% → 49.6% | 0.823 → 0.827 |
| 4b | Lincoln | vote6 | 51.7% → 54.4% | 0.832 → 0.842 |
| 4b | Lincoln | vote-offsets-l1 | 52.9% → 54.0% | 0.829 → 0.829 |
| 4b | Lincoln | vote-prompts-o0 | 58.2% → 60.9% | 0.845 → 0.856 |
| 4b | Stanton | o0-l1 | 79.0% → 80.2% | 0.918 → 0.918 |
| 4b | Stanton | o0-w1 | 79.8% → 81.9% | 0.913 → 0.922 |
| 4b | Stanton | o1-l1 | 76.1% → 74.1% | 0.912 → 0.904 |
| 4b | Stanton | o1-w1 | 70.4% → 71.6% | 0.886 → 0.887 |
| 4b | Stanton | o2-l1 | 79.8% → 81.1% | 0.912 → 0.912 |
| 4b | Stanton | o2-w1 | 79.0% → 80.2% | 0.907 → 0.908 |
| 4b | Stanton | mean-of-singles | 77.4% → 78.2% | 0.908 → 0.909 |
| 4b | Stanton | vote6 | 79.8% → 81.1% | 0.912 → 0.912 |
| 4b | Stanton | vote-offsets-l1 | 80.7% → 81.9% | 0.918 → 0.918 |
| 4b | Stanton | vote-prompts-o0 | 79.8% → 81.1% | 0.921 → 0.922 |
| teacher | Lincoln | o0-l1 | 40.6% → 41.8% | 0.800 → 0.800 |
| teacher | Lincoln | o0-w1 | 47.9% → 49.0% | 0.825 → 0.825 |
| teacher | Lincoln | o1-l1 | 38.7% → 39.8% | 0.788 → 0.788 |
| teacher | Lincoln | o1-w1 | 45.2% → 46.4% | 0.816 → 0.816 |
| teacher | Lincoln | o2-l1 | 42.5% → 41.8% | 0.796 → 0.790 |
| teacher | Lincoln | o2-w1 | 44.4% → 45.6% | 0.812 → 0.812 |
| teacher | Lincoln | mean-of-singles | 43.2% → 44.1% | 0.806 → 0.805 |
| teacher | Lincoln | vote6 | 42.9% → 44.1% | 0.804 → 0.804 |
| teacher | Lincoln | vote-offsets-l1 | 39.1% → 40.2% | 0.792 → 0.792 |
| teacher | Lincoln | vote-prompts-o0 | 47.9% → 49.0% | 0.825 → 0.825 |
| teacher | Stanton | o0-l1 | 81.9% → 79.8% | 0.914 → 0.906 |
| teacher | Stanton | o0-w1 | 79.0% → 81.1% | 0.906 → 0.915 |
| teacher | Stanton | o1-l1 | 75.3% → 73.3% | 0.898 → 0.891 |
| teacher | Stanton | o1-w1 | 79.0% → 80.2% | 0.906 → 0.907 |
| teacher | Stanton | o2-l1 | 72.0% → 73.3% | 0.897 → 0.898 |
| teacher | Stanton | o2-w1 | 77.4% → 79.4% | 0.891 → 0.900 |
| teacher | Stanton | mean-of-singles | 77.4% → 77.8% | 0.902 → 0.903 |
| teacher | Stanton | vote6 | 80.2% → 81.5% | 0.914 → 0.915 |
| teacher | Stanton | vote-offsets-l1 | 81.1% → 79.0% | 0.914 → 0.906 |
| teacher | Stanton | vote-prompts-o0 | 81.1% → 82.3% | 0.914 → 0.915 |

## Measurement card

- **Truth:** the owner's blind rulings of 2026-10-31 (W46.seg-truth-sheet, 75 gaps) folded into the Stanton CSV,
  the CREST and Lincoln manifests and SC0122's lock; the rest of each truth unchanged (Stanton: the owner's
  2026-10-05 check; CREST, Lincoln: one Codex agent's audit, its ambiguous gaps now ruled or unsure). Seven gaps the
  owner could not rule are excluded from every score.
- **Selection:** the cases are the sheet's (by rule, the agent's own ambiguity notes and a seeded stratified draw);
  no route's answer chose a case, no ABBYY text was used.
- **Comparison:** every route rescored from its own cached answers with the same scorer on the same truth, before
  and after; nothing refit or re-chosen (the options levels and mix rule are the frozen ones).
- **Noise:** Stanton's change is 2 gaps of 238; CREST's routes now differ by at most one gap except the 2B; on
  Lincoln a gap is about 1.2 points of pages exact. Rerun floors as in `seg-context.md`. SC0122: 0 of 60, interval
  above.
- **Scope:** it does not re-rule the method prompts or the app's handling of an issue run
  (W46.seg-magazine-rule-redo), does not score the routes on the three locked boxes (W46.seg-boxes-score), and does
  not rule CREST or Lincoln gaps the agent did not mark.
