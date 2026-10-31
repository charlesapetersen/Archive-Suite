# W46.ocr-new-open on Sherlock: three new open readers on the 895 and the 96

The untested open readers, run through the open sweep's own harness on Sherlock (submitted 2026-10-22,
collected 2026-10-24; `execution-plans/items/W46.ocr-new-open.md`). The settings were the same as the open sweep:
vLLM 0.31.0, context 16,384, temperature 0, thinking off, 8,192 output tokens and eight requests at a time. Each run
used one Sherlock GPU with 48 or 80 GB, so its speed is not comparable with the L40S rows. Three of the seven
submitted readers came back with readings on both sets. Receipts: `ArchiveOCRBench/data/new-open-sherlock-20261024.json`.
The 96-page summaries are in `farmshare/truth/<label>-<job>/`.

## Results

NES %, where a cap, error or blank scores 0. The comparison rows are the open sweep (895) and the truth96 runs (96).

| Reader | Weights | 895 NES | answered | 895 NES of answered | 440 NES | 96 NES | 96 answered |
|---|---|---|---|---|---|---|---|
| Xiaomi-OCR-0, card's Markdown prompt | 1.75 GB bf16 | **62.2** | 894 | 62.3 | 50.7 | 88.67 | 96 |
| Qwen3.8 27B fp8, panel prompt | 30.9 GB | 56.1 | 722 | 69.5 | 41.3 | 93.44 | 96 |
| PaddleOCR-VL 1.6, `OCR:` | 1.92 GB bf16 | 44.5 | 669 | 59.5 | 30.8 | 88.87 | 94 |
| *Qwen3.6 27B fp8 (open sweep)* | | 63.3 | 798 | 71.0 | | 95.25 | |
| *LightOnOCR-3 4B (open sweep)* | | 62.9 | 810 | 69.5 | | 89.38 | |
| *LightOnOCR-3 0.8B (open sweep)* | | 56.7 | 750 | 67.6 | | 88.00 | |
| *GLM-OCR (open sweep)* | | 48.6 | 680 | 64.0 | | 90.90 | |
| *PaddleOCR-VL 1.5 (open sweep)* | | 38.9 | 545 | 63.8 | | 83.78 | |

By stratum on the 895 (NES %, failures as 0):

| Stratum | Xiaomi-OCR-0 | PaddleOCR-VL 1.6 | Qwen3.8 27B | Qwen3.6 27B | LightOnOCR-3 4B | LightOnOCR-3 0.8B |
|---|---|---|---|---|---|---|
| L1 English letters and diaries | 85.3 | 73.1 | 82.7 | 88.4 | 87.8 | 83.8 |
| L2 English manuscripts | 76.1 | 60.9 | 73.2 | 73.5 | 77.4 | 72.4 |
| L3 Typescripts | 93.1 | 93.8 | 95.1 | 96.0 | 93.5 | 90.7 |
| L4 Ledgers and forms | 52.2 | 41.1 | 58.4 | 69.3 | 55.0 | 52.1 |
| L9 Newspapers | **95.2** | 0.0 | 81.3 | 93.6 | 92.5 | 84.5 |
| N2 Cyrillic | **27.1** | 7.2 | 10.6 | 17.1 | 8.9 | 4.2 |
| N5 Chinese print | 79.7 | 56.5 | 81.3 | 80.7 | 72.8 | 74.3 |
| N6 Devanagari print | **78.7** | 53.9 | 59.1 | 63.3 | 65.4 | 59.3 |

The full table for every stratum and subset is in `new-open-sherlock-20261024.csv`, and the page rows are in `-pages.csv`.

## Paired against the incumbents, and order-free

The measurement audit asks for these (OCR-2, OCR-6 and OCR-9 in
`execution-plans/processing-review/11-measurement-audit.md`). `ocr_new_open_paired.py` reads `ocr_rescore.py`'s
per-page scores and writes `../new-open-paired.json`. Each cell is the new route minus the incumbent, in NES points,
with its 95% bootstrap interval. Strict pairs every page and counts a failure as 0. Answered pairs only the pages
both routes answered. Every failure here is the model's: the Sherlock runs logged no request errors, so none is a
provider's. Each run read once (no rerun-noise figure exists yet, OCR-3), so a difference inside about 1-2 points is
not a ranking.

| Set | Route | vs Qwen3.6 27B, strict | answered | vs LightOnOCR-3 4B, strict | answered | bowF1 |
|---|---|---|---|---|---|---|
| 96 | Xiaomi-OCR-0 | -5.6 (-8.5 to -2.9) | -6.2 (-9.0 to -3.8) | -0.7 (-2.8 to +1.3) | -0.7 (-2.8 to +1.3) | 0.922 |
| 96 | Qwen3.8 27B | -0.8 (-3.7 to +2.1) | -1.8 (-4.2 to -0.1) | +4.1 (+1.1 to +7.3) | +4.1 (+1.1 to +7.3) | 0.965 |
| 96 | PaddleOCR-VL 1.6 | -5.4 (-8.6 to -2.9) | -4.6 (-7.2 to -2.5) | -0.5 (-4.5 to +3.3) | +0.7 (-2.9 to +4.3) | 0.903 |
| 895 | Xiaomi-OCR-0 | -1.0 (-2.4 to +0.4) | -5.2 (-6.4 to -4.1) | -0.7 (-1.8 to +0.5) | -3.4 (-4.4 to -2.4) | 0.583 |
| 895 | Qwen3.8 27B | -7.2 (-8.8 to -5.6) | -3.1 (-4.0 to -2.3) | -6.8 (-8.4 to -5.2) | -1.6 (-2.5 to -0.6) | 0.578 |
| 895 | PaddleOCR-VL 1.6 | -18.8 (-20.7 to -16.9) | -11.9 (-13.2 to -10.7) | -18.4 (-20.2 to -16.7) | -10.4 (-11.6 to -9.2) | 0.418 |

For comparison, the order-free bag-of-words F1 (NewsBench's, failures counted) is 0.960 on the 96 and 0.626 on the
895 for Qwen3.6 27B, and 0.931 and 0.641 for LightOnOCR-3 4B (`../ocr-scorers.md`).

## What it shows

- **No reader here changes the owner's-material pick.** On the 96, Qwen3.8 27B scores 93.44. That is below Qwen3.6 27B
  (95.25 by its own run, 94.3 in the rescore's local-panel reading; answered-only -1.8 points, -4.2 to -0.1). It is
  close to the earlier FarmShare run of the same checkpoint with an fp8 KV cache (93.10). It is the only new route
  ahead of LightOnOCR-3 4B on the 96, and it has the best bowF1 of the three (0.965, level with Qwen3.6's 0.960).
  On the 895 it is worse than 3.6 both ways (answered -3.1, -4.0 to -2.3). Its 173 failures there are 102 token caps
  and 69 replies with `TEXT` written without its colon, mostly Charters, Arabic, Hebrew and Cyrillic, which the
  panel's parser rejects. So the strict gap overstates the reading gap, but the answered gap stands. The 3.8
  checkpoint is not an upgrade for this panel.
- **Xiaomi-OCR-0 is the most reliable small reader on the public set, not the most accurate.** It has 1.75 GB of
  weights, about 0.9B parameters on the Qwen3.5 architecture. It answered 894 of 895 pages, the lowest failure rate
  of any VLM in the sweep, where LightOnOCR-3 4B failed 85. That is why its strict 62.2 is level with LightOnOCR-3 4B
  (62.9; -0.7, -1.8 to +0.5). On the pages both answered it reads 3.4 points lower (-4.4 to -2.4). Its bowF1 is
  0.583 against 0.641, and it writes Markdown or OTSL markup on 192 pages. It leads every reader on newspapers
  (L9 95.2), Cyrillic and Devanagari. On the owner's 96 it is level with LightOnOCR-3 4B (-0.7, -2.8 to +1.3) and
  below GLM-OCR (90.90). Its clippings score (83.78) is below every other small VLM except PaddleOCR-VL 1.5. A likely
  cause, not checked page by page, is the card's prompt, which says to ignore headers and footers. For the 16 GB
  laptop tier it is an alternative to LightOnOCR-3 4B at a fifth of the size, not a replacement. That turns on its
  Mac seconds and memory (the MLX arm of this item).
- **PaddleOCR-VL 1.6 fixes little of 1.5's whole-page problem.** It answers 669 of 895 against 1.5's 545. It still
  reads nothing on newspapers, where all 15 L9 pages cap, as 1.5's did. On the 96 it improves to 88.87 from 83.78.
  As with 1.5, its place is on regions (W46.ocr-regions), not on the whole page.

## Measurement card

- **Truth:** on the 895, each public dataset's own ground-truth transcription, frozen with the set
  (`bench-corpus/manifest.jsonl` checksums); no scored route drafted it and the owner did not check it. On the 96, the
  panel's adjudicated truth: 98.0% of its words are where both drafters (Claude Opus 5.5 and Gemini 3.8 Flash) agreed,
  2.0% come from the 324 spans the owner adjudicated. None of the three new readers is a drafter or a drafter's
  relative; the drafter family's lead on agreed words (`../ocr-truth-bias.md`) favours neither side of these pairs,
  whose incumbents are not drafters either.
- **Selection:** none by a tested route or by ABBYY text: the frozen 895 and all 96 scored pages.
- **Comparison:** the open sweep's harness unchanged, on the same images, with vLLM 0.31.0, temperature 0, thinking
  off and 8,192 tokens, as the incumbents read them. Only the prompt differs where a card names its own (Xiaomi-OCR-0's
  Markdown prompt, PaddleOCR-VL's `OCR:`); Qwen3.8 has the panel prompt, as Qwen3.6 did. Both OCR sets, in this item.
- **Noise:** n = 895 and 96, paired 95% bootstrap intervals above. Each run read once; these are local greedy routes,
  so the tie rule (`../ocr-rerun-noise.md`) applies the paired interval alone: a gap whose interval crosses 0 is a tie.
  Xiaomi-OCR-0 and LightOnOCR-3 4B tie strict on both sets; on the 96 Qwen3.8 27B and Qwen3.6 27B tie strict.
- **Scope:** whole-page reading with one prompt each. It does not settle region reading (W46.ocr-regions), the box
  readers (W46.ocr-new-open-boxes), the readers that did not run (below; W46.ocr-new-open-rest), or Mac speed beyond
  the two MLX runs recorded below.

## Not scored

- OvisOCR2: the three-page pilot capped or came back empty, so the full run never started.
- TeleOCR: vLLM 0.31 does not support its rotary embedding.
- MiniCPM-V 4.7 1B and 35B-A3B: the architecture is not in the installed vLLM, and the run allows no environment
  upgrade.
- Unlimited-OCR, Nemotron-Parse 2.0, granite-docling, dots.ocr and Chandra-2 were never submitted. Each needs more
  than the frozen collector's one image and one prompt (`execution-plans/items/W46.ocr-new-open.md`).
- Churro-3B was measured earlier on the 96 as `churro-1855420`.

## Reproduce

Run from `ArchiveProcessor/scripts/segbench/corpus`, with `S=~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results` and
`RC="~/Claude/Long term storage/FarmShare-20261019/recovery"`:

```
uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python farmshare_expanded_report.py \
  --manifest "$RC/manifest-895.jsonl" --base "$RC/manifest-440.jsonl" --name new-open-sherlock-20261024 \
  --out ../../../segbench-results/bench-corpus \
  --route "paddleocr-vl1.6=$S/new-open-895/paddleocr-vl16/results/ocr/paddleocr-vl16:native" \
  --route "xiaomi-ocr-0=$S/new-open-895/xiaomi-ocr-0/results/ocr/xiaomi-ocr-0:native" \
  --route "qwen3.8-27b=$S/new-open-895/qwen38-27b-fp8/results/ocr/qwen38-27b-fp8:panel"
# sacct-96.txt: the header line plus jobs 49202331, 49202334 and 49202336 from $S/collection-20261024-slurm.txt
uv run --with rapidfuzz --with 'sacrebleu==2.5.1' --with regex --with numpy python farmshare_truth96.py \
  --out ../../../segbench-results/farmshare/truth --sacct sacct-96.txt \
  --route "paddleocr-vl1.6=$S/new-open-96/paddleocr-vl16:native" --route "xiaomi-ocr-0=$S/new-open-96/xiaomi-ocr-0:native" \
  --route "qwen3.8-27b-sherlock=$S/new-open-96/qwen38-27b-fp8:panel"
```
