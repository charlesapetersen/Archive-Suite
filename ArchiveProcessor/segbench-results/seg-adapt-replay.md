# The continuation without the owner's corpus replay set (W46.kit-continuation-replay)

**Verdict: train the continuation on the corrections alone.** That is now `kit_continuation.py rows`' default.
W46.seg-adapt-lora's k = 200 arm also replayed three windows of the corpus 2B's own training set for each correction
window. No kit user except the owner has that set. Without it, on the same Lincoln box 2, the continuation scored 4.5
errors per 100 gaps against 4.9 with the corpus replay. The change was -0.4, with a 95% interval of -1.9 to +0.9. It
also found the same 67 of 69 catalogue starts. Replaying three public TABME++ windows for each correction window
instead gave 5.3 per 100 (+0.4, interval -2.0 to +2.9) but lost five more catalogue starts (62 of 69). It cut false
splits by trading them for false merges, so it fails the rule.

## The arms and the rule (fixed before any run, `seg_adapt_replay.py` docstring)

- `none`: box 1's k = 200 correction rows alone, the same 62 windows as k = 200's corrections.
- `public`: the same rows plus 186 TABME++ windows, a seeded draw (41) from W46.seg-tabme's frozen fs-seg-2b requests.
  Each target is the shipped 2B's own reply on that window, with every boundary set to TABME++'s truth.
- Both arms trained onto the merged corpus 2B exactly as k = 200 had (train_seg.py, rank 16, lr 1e-4, two epochs,
  `--max-len 20480`). Both answered the same 175 frozen scoring windows, and are paired against the base and k = 200
  answers already home from W46.seg-adapt-lora.
- The rule: the default is the cheapest arm that meets both tests. First, its box-2 change against k = 200 has an
  interval whose high end is below +3 errors per 100 gaps. Second, it loses no more catalogue starts on box 2 than
  k = 200 does. `none` is the cheaper arm, and it meets both.

## Results

Lincoln box 2, whole (244 gaps, 70 catalogue items; nothing trained on it):

| Arm | Errors / 100 | False splits | False merges | Catalogue starts | Pages exact | Against k = 200 (95%) | Against the 2B (95%) |
|---|---|---|---|---|---|---|---|
| Corpus 2B (base) | 17.2 | 41 | 1 | 68 / 69 | 52.1% | | |
| k = 200, corpus replay | 4.9 | 10 | 2 | 67 / 69 | 86.8% | | -12.3 (-18.8 to -7.4) |
| k = 200, no replay | **4.5** | 9 | 2 | **67 / 69** | 87.2% | -0.4 (-1.9 to +0.9) | -12.7 (-19.3 to -7.9) |
| k = 200, TABME++ replay | 5.3 | 6 | 7 | 62 / 69 | 80.9% | +0.4 (-2.0 to +2.9) | -11.9 (-18.6 to -6.8) |

Lincoln box 1, the 59 gaps after the first 200 (17 items): all three k = 200 arms made 3 errors (5.1 per 100) against
the base's 6. `none` matches k = 200 gap for gap (change 0.0, interval 0.0 to 0.0). `public` makes the same count, one
of them a missed catalogue start (15 of 16).

Training on Sherlock (batch 20261113-092722, six jobs, none failed): `none` took 7 minutes (62 windows, 15 steps) and
`public` 32 (248 windows, 62 steps). Each scoring run took 3 to 5 minutes. That came to about 0.84 GPU-hours in all,
against 1.35 estimated. No calls, $0.

## What the kit changed

- `kit_continuation.py rows` now defaults to the corrections alone. `--no-replay` is still accepted, and
  `--replay DATA` still mixes in a train_seg.py data set's no-text windows, three for each correction window.
  `data.json` counts both the corrections alone and the full corpus-replay ratio as measured recipes.
- README §"The continuation" gives these figures. It also advises against replaying a public set.

## Measurement card

- **Truth.** It is W46.seg-adapt-lora's, unchanged. The scorer refuses a changed manifest hash. Box 1 is
  `public-segmentation/lincoln.json`: agent-audited, with the owner's rulings on its disputed gaps folded in, and 3
  unsure gaps. Box 2 is `lincoln2.json`: the 70 catalogue starts, plus Gemini 3.7 Flash's 'same' calls on 175
  within-item gaps, taken as continuations. Its 12 'new' calls are unsure gaps. So box 2 cannot see a start missed
  inside an item, and its false merges are catalogue starts only. Gemini is not a scored route.
- **Selection.** The boxes, k = 200 and the 175 scoring windows are those of W46.seg-adapt-lora. The TABME++ windows
  are a seeded draw from the windows whose 2B reply parses and covers every gap. No tested route and no ABBYY text
  chose anything.
- **Comparison.** All four arms answered the same frozen fs-seg-2b requests: prompt o1, 1024 px images and Vision
  text, served by vLLM with the same arguments on one Sherlock GPU each. The new arms were trained from the same
  merged 2B, rebuilt by this batch's merge job. One difference: the TABME++ rows carry page text, while the corpus
  replay rows had none. The `public` arm therefore trained on text-bearing replay where k = 200's replay was
  image-only.
- **Noise.** The paired 95% intervals resample catalogue items. W46.seg-adapt-lora measured the rerun floor for the
  same requests at 3 of 207 gaps (+1.4 per 100). The -0.4 of `none` against k = 200 lies inside that floor and its
  interval: a tie, not a gain. `public`'s 5 lost starts are 5 of 69 items, and a single retraining could move them.
  There is one training seed per arm, so the spread from retraining is not measured.
- **Scope.** One material (Lincoln Papers correspondence), two adjacent boxes, k = 200 only. It shows that the corpus
  replay bought nothing here. It does not show that replay is never needed: a smaller k, a longer training run, or a
  material further from the corpus might forget more. The kit's gate still checks each user's continuation against
  the shipped 2B on their own next box, so a continuation that forgets does not load. The material's own
  accepted-gap windows were not measured as a replay. With `none` meeting the rule, that arm is not needed.

Sources: `seg-adapt-replay.json` (`seg_adapt_replay.py score`), the Sherlock artifact
`$AGENT_STATE/artifacts/seg-adapt-replay-20261113` (answers, adapters, train logs, sacct), and `seg-adapt-lora.md`.
