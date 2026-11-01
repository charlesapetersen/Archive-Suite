# W46.ocr-new-open-sherlock: Infinity-Parser2-Pro on the 895 and the 96

`infly/Infinity-Parser2-Pro` (revision `b27d4701`, Apache-2.0) is a document-parsing fine-tune of Qwen3.5 35B-A3B,
with 70.2 GB of BF16 weights. It was run through W46.ocr-new-open's harness on Sherlock, in batch 20261031-131437
(jobs 50536488 setup, 50536489 for the 895, 50536490 for the 96, all COMPLETED). The settings were the open sweep's:
vLLM 0.31.0, context 16,384, temperature 0, thinking off, 8,192 output tokens and eight requests at a time. The one
change was tensor-parallel 2, on two Sherlock GPUs with 48 or 80 GB. The prompt was the package's `doc2md`
(`infinity-parser2` 0.4.0, `PROMPT_DOC2MD`; the setup job checked that it matched the transcription). Receipts:
`ArchiveOCRBench/data/new-open-sherlock-20261031.json`. The 96-page summary is in
`farmshare/truth/infinity-parser2-pro-50536490/`.

**Fence.** Every reply on both sets came back wrapped in one ```` ```markdown ```` fence. `farmshare_results.reading`
now reads a native reply that is wrapped whole in one fence inside the fence, so the fence is not scored as a word.
That changes no earlier route's score: no saved native reading from any earlier route starts with a fence (checked
over every FarmShare and Sherlock native folder, 2026-10-31), and the rescore's other 340 summary rows are unchanged.

## Results

NES %, where a cap, error or blank scores 0. The comparison rows are from `../ocr-scorers.md` (the 96 on the
corrected hand truth, W46.ocr-hands-rescore).

| Reader | 895 NES | answered | 895 NES of answered | 440 NES | 96 NES | 96 answered | bowF1 96 | bowF1 895 |
|---|---|---|---|---|---|---|---|---|
| **Infinity-Parser2-Pro, doc2md** | **64.2** | 874 | 65.8 | 51.4 | 93.13 | 96 | 0.954 | **0.661** |
| *Qwen3.6 27B fp8 (open sweep; 96: local panel)* | 63.3 | 798 | 71.0 | | 94.35 | 95 | 0.960 | 0.626 |
| *LightOnOCR-3 4B (open sweep)* | 62.9 | 810 | 69.5 | | 89.43 | 96 | 0.931 | 0.641 |
| *Xiaomi-OCR-0 (Sherlock)* | 62.2 | 894 | 62.3 | 50.7 | 88.70 | 96 | 0.922 | 0.583 |

Its 21 failures on the 895 are all token caps (8,192); the run logged no request errors. They fall in L2 (2), L5 (1),
L6 (4), L9 (1), N1 (2), N2 (5), N3 (2), N4 (2) and N5 (2). On the 96 it answered every page. On the 13 clippings
it scores 88.19.

By stratum on the 895 (NES %, failures as 0). The other columns are from `new-open-sherlock-20261024.md`.

| Stratum | Infinity-Parser2-Pro | Qwen3.6 27B | LightOnOCR-3 4B | Xiaomi-OCR-0 |
|---|---|---|---|---|
| L1 English letters and diaries | **92.1** | 88.4 | 87.8 | 85.3 |
| L2 English manuscripts | **80.0** | 73.5 | 77.4 | 76.1 |
| L3 Typescripts | 95.7 | 96.0 | 93.5 | 93.1 |
| L4 Ledgers and forms | 66.9 | 69.3 | 55.0 | 52.2 |
| L9 Newspapers | 86.2 | 93.6 | 92.5 | 95.2 |
| N2 Cyrillic | 11.6 | 17.1 | 8.9 | 27.1 |
| N5 Chinese print | 80.2 | 80.7 | 72.8 | 79.7 |
| N6 Devanagari print | 78.3 | 63.3 | 65.4 | 78.7 |

The full table for every stratum and subset is in `new-open-sherlock-20261031.csv`, and the page rows are in `-pages.csv`.

## Paired against the incumbents

From `../new-open-paired.json` (`ocr_new_open_paired.py` over `ocr_rescore.py`'s page scores). Each cell is
Infinity-Parser2-Pro minus the incumbent, in NES points, with its 95% bootstrap interval. Strict pairs every page and
counts a failure as 0. Answered pairs only the pages both routes answered.

| Set | vs Qwen3.6 27B, strict | answered | vs LightOnOCR-3 4B, strict | answered |
|---|---|---|---|---|
| 96 | -1.2 (-3.9 to +1.7) | -2.3 (-4.4 to -0.6), n = 95 | +3.7 (+1.1 to +6.6) | +3.7 (+1.1 to +6.6) |
| 895 | +1.0 (-0.3 to +2.3) | -1.7 (-2.8 to -0.7), n = 787 | +1.4 (+0.1 to +2.6) | -0.2 (-1.3 to +0.9), n = 797 |

## What it shows

- **The best whole-page open reader on the 895 counting failures, but not on the pages it answers.** Strict, it is
  level with Qwen3.6 27B (+1.0, a tie) and ahead of LightOnOCR-3 4B (+1.4). It caps on 21 pages, where 3.6 fails 97
  and LightOn 85. On the pages both answered it reads 1.7 points below 3.6, and it ties LightOn. It has the best
  order-free bowF1 of any open route on the 895 (0.661, against 0.626 and 0.641). So it gets more of the words right
  more often, while 3.6 is more exact on the pages 3.6 does finish.
- **Hands, as the gap audit expected.** It leads every open reader on English letters and diaries (L1 92.1, +3.7 on
  3.6) and English manuscripts (L2 80.0, +6.5). It also leads on Devanagari print (+15 on 3.6). It is below 3.6 on
  newspapers (86.2 against 93.6) and ledgers, and like every open model it fails on Cyrillic.
- **On the owner's 96 it does not displace Qwen3.6 27B.** Strict is a tie (-1.2, -3.9 to +1.7), and on the 95 pages
  both answered it is 2.3 points lower (-4.4 to -0.6). It is clearly above LightOnOCR-3 4B (+3.7), level with Qwen3.8 27B
  on Sherlock (93.46), and above the two small Sherlock readers (about 88.8). Its bowF1 there (0.954) is level with 3.6's 0.960.
- **For a cluster profile it is a real candidate, not a pick.** It is a 3B-active MoE. On two Sherlock cards it read
  the 895 in 1,599 s of collector time (about 1,000 pages an hour per GPU) and the 96 in 148 s (1,206 pages an hour
  per GPU). The two GPU jobs took 32 and 8 minutes with model load, 1.3 GPU-hours in all,
  against the 16 reserved and about 3 estimated. Those speeds are on Sherlock cards of unrecorded type, not the L40S rows. Whether the cluster profile
  takes it over Qwen3.6 27B, which needs one card, is a Phase 4 decision (W46.review-phase4). Its Reading the
  Archive scores are W46.ocr-new-open-gold's.

## Measurement card

- **Truth:** on the 895, each public dataset's own ground-truth transcription, frozen with the set
  (`bench-corpus/manifest.jsonl` checksums). No scored route drafted it, and the owner did not check it. On the 96,
  the panel's adjudicated truth with the owner's corrected hand sheet (W46.ocr-hands-rescore). Its agreed words come
  from the two drafters (Claude Opus 5.5 and Gemini 3.8 Flash). Infinity-Parser2-Pro is not a drafter. It is a
  Qwen3.5 fine-tune, and so is the Qwen3.6 incumbent; neither is a drafter's relative.
- **Selection:** none by a tested route or by ABBYY text: the frozen 895 and all 96 scored pages.
- **Comparison:** the open sweep's harness unchanged, on the same images, with vLLM 0.31.0, temperature 0, thinking
  off and 8,192 tokens, as the incumbents read them. It differs in tensor-parallel 2 and in the package's own prompt,
  as the other native readers used their cards' prompts. The card's 65,536 context and 32,768 output tokens were not
  used, so a page that would finish under the card's limits counts as a cap here. Both OCR sets, in this item.
- **Noise:** n = 895 and 96, paired 95% bootstrap intervals above. It read each set once. This is a local greedy
  route, so the tie rule (`../ocr-rerun-noise.md`) applies the paired interval alone: a gap whose interval crosses 0
  is a tie. It ties Qwen3.6 27B strict on both sets and LightOnOCR-3 4B answered-only on the 895.
- **Scope:** whole-page reading with one prompt. This does not settle the card's own longer limits (the 21 caps), the
  `doc2json` layout output, region reading (W46.ocr-regions), Reading the Archive's gold (W46.ocr-new-open-gold), or
  Mac use (the BF16 weights do not fit an 18 GB Mac).

## Reproduce

Copy the collected session folders from `$AGENT_STATE/artifacts/new-open-sherlock-20261031/{895,96}/infinity-parser2-pro`
to `$S/new-open-{895,96}/`. Then run from `ArchiveProcessor/scripts/segbench/corpus`, with
`S=~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results` and
`RC="~/Claude/Long term storage/FarmShare-20261019/recovery"`:

```
uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python farmshare_expanded_report.py \
  --manifest "$RC/manifest-895.jsonl" --base "$RC/manifest-440.jsonl" --name new-open-sherlock-20261031 \
  --out ../../../segbench-results/bench-corpus \
  --route "infinity-parser2-pro=$S/new-open-895/infinity-parser2-pro/results/ocr/infinity-parser2-pro:native"
# infinity-sacct-96.txt: the header JobID|JobName|State|ExitCode|Elapsed|Start|End and job 50536490's row (00:07:49)
uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python farmshare_truth96.py \
  --out ../../../segbench-results/farmshare/truth --sacct "$S/new-open-96/infinity-sacct-96.txt" \
  --gpus infinity-parser2-pro=2 --route "infinity-parser2-pro=$S/new-open-96/infinity-parser2-pro:native"
cd .. && uv run ... python ocr_rescore.py && uv run ... python ocr_new_open_paired.py
```
