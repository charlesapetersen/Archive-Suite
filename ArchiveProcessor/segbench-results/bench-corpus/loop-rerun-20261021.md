# Whether looping pages are recoverable (W46.ocr-loops)

Every page that ran to the 8,192-token limit in the open sweep ([`open-sweep-20261019.md`](open-sweep-20261019.md)),
nearly all of them repetition loops and each scored 0 there, read again five ways and scored on those pages only,
failures as 0. 1,652 capped pages across ten routes on the 895 public pages, and the 18 caps of the owner's 96 (15
from the truth96 cluster runs, three from Qwen3-VL 8B 4-bit on the Mac). Cluster runs 2026-10-21 to 23 (FarmShare,
then Sherlock), Mac arms 2026-10-21, scored 2026-10-23. No hosted call; no money spent.

## Short answer

- **Partly, and not by the same model.** Read by another reader, the 1,652 caps score 50.3 NES pooled (readers first,
  below), against 29.5 when the same model is retried first. The best arm per page, picked with the truth, reaches
  54.4, so the readers-first order is close to what these arms can give.
- **kraken PP-OCRv6 is the best single fallback on Latin-script pages**: 63.3 NES on the 851 Latin caps, every one
  answered (65.6 on sources its public training list names, so an upper bound there; 59.1 on the rest). It is a CTC
  line recogniser and cannot loop.
- **A second open reader** (LightOnOCR-3 4B's saved reading; Qwen3.6 27B's for LightOnOCR-3 4B's own caps) scores 46.6
  on the Latin caps and 27.3 on the others, and is the only arm that helps the non-Latin pages much.
- **N-gram blocking stops the loop but not the misreading**: it answers 1,506 of 1,573 caps (96%; 67 still capped)
  in a mean 1,356 tokens against 8,192, but scores only 20.2-39.2 NES by route. It beats the second reader on the
  non-Latin caps of the 27B-class readers (Qwen3.6 27B 36.6 against 18.5, Qwen3.5 27B 30.9 against 14.5, Qwen3.6
  35B-A3B 30.7 against 12.0), where LightOnOCR-3 4B reads poorly, but even there it is worth more as the fallback when
  the second reader fails than as the first try (second then n-gram 34.8 on those 129 pages, n-gram first 32.9).
- **The half-size retry fails**: 351 of 1,573 answered, 1,216 capped again, 4.2-11.0 NES pooled. Drop it.
- On the 895, the readers-first cascade lifts every route's whole-set NES by 3.8-20.8 points (PaddleOCR-VL 1.5
  38.9 → 59.7, GLM-OCR 48.6 → 62.2, Qwen3-VL 8B 53.3 → 66.8, Qwen3.6 27B 63.3 → 68.4).
- **The 96 disagree on the order**: on its 18 caps the second reader first scores 74.9, kraken first 63.8, retry first
  57.4 (best arm per page 84.2). kraken read one LightOnOCR-3 0.8B cap as nothing usable (0.0) and lost to the second
  reader on PaddleOCR-VL's eleven (62.6 against 77.6). Eighteen pages, eleven of them one route's, cannot settle the
  order for typescript; they say a second VLM reader is at least as good a first fallback on the owner's material.
- **The Mac's three MLX loops** (Qwen3-VL 8B 4-bit, p018, p031, p071) all stop with either fix, each in under a minute
  against 7.3 minutes a loop: half size 87.5, second reader 83.3, n-gram 75.8, kraken 73.1; the same model in bf16
  under vLLM read them at 61.4 (2 of 3 answered). Three pages only.

What it feeds (gap audit §5 item 3): the local route's loop guard and the cascade's fallback. Stop a loop early
(any reply at the cap is a failure; the sweep's caps spent 8,192 tokens each), never retry at half size, and hand the
page to a reader that cannot loop (kraken PP-OCRv6 on Latin lines, free on the Mac, 64 MB) or to a second VLM. The
order between those two on the owner's pages is not settled by 18 caps.

## Arms

| arm | what | where |
|---|---|---|
| ngram | same model and prompt, vLLM `NGramPerReqLogitsProcessor` (no 4-token sequence repeated, window 8,192), V1 runner | FarmShare, then Sherlock; one L40S each |
| half | same model and prompt, image long edge 1,200 px, no processor | as above |
| second | another open route's saved reading of the same page from the sweep: LightOnOCR-3 4B, or Qwen3.6 27B for LightOnOCR-3 4B's caps | no new calls |
| kraken-ppocrv6 | kraken 7.1.1, PP-OCRv6 medium (Zenodo 21788410, Apache-2.0) on blla lines, Latin strata L1-L9 only (`loop_kraken.py`) | the Mac |
| ppocrv6 | the sweep's stock PP-OCRv6 line pipeline reading | no new calls |
| cascade | retry first: the first of ngram, half, second, kraken-ppocrv6, ppocrv6 that answered (the order filed) | scoring only |
| cascade-readers | readers first: kraken-ppocrv6, second, ngram, ppocrv6 | scoring only |

The readers-first order was chosen **after** the arms were scored, from the 895's pooled figures, so its 895 score
is fitted to these pages; the 96 are the check, and there the second reader first does better (above). Other orders
tried on the same pages: second first 45.2 on the 895; kraken then n-gram then second 44.4; kraken, second,
PP-OCRv6 without n-gram 47.6.

## The 895 (NES % on the capped pages; answered / pages)

| route | caps | ngram | half | second | kraken-ppocrv6 | ppocrv6 | retry first | readers first | 895 before | after, retry first | after, readers first |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 215 | 26.8 (208) | 2.9 (45) | 47.5 (176) | 70.7 (78/78) | 13.4 (215) | 28.7 | 56.5 | 48.6 | 55.5 | 62.2 |
| lightonocr3-4b | 76 | 32.0 (76) | 6.9 (19) | 27.8 (46) | 67.4 (17/17) | 12.4 (76) | 32.0 | 45.1 | 62.9 | 65.6 | 66.7 |
| lightonocr3-0.8b | 145 | 29.3 (143) | 8.5 (38) | 25.9 (86) | 62.5 (61/61) | 15.0 (144) | 29.5 | 43.3 | 56.7 | 61.4 | 63.7 |
| paddleocr-vl1.5 | 350 | 20.2 (346) | 6.2 (62) | 47.4 (285) | 64.0 (223/223) | 22.4 (350) | 20.9 | 53.4 | 38.9 | 47.0 | 59.7 |
| qwen3-vl-8b | 236 | 27.4 (192) | 8.1 (39) | 36.8 (173) | 62.6 (129/129) | 19.1 (236) | 33.2 | 51.2 | 53.3 | 62.0 | 66.8 |
| qwen3.5-4b | 247 | 27.9 (242) | 6.7 (38) | 38.0 (182) | 67.9 (128/128) | 17.8 (247) | 28.5 | 51.9 | 51.0 | 58.9 | 65.4 |
| qwen3.6-27b | 97 | 39.2 (96) | 16.9 (42) | 30.8 (65) | 55.6 (55/55) | 20.1 (97) | 39.2 | 47.8 | 63.3 | 67.5 | 68.4 |
| qwen3.5-27b | 131 | 33.7 (128) | 9.9 (35) | 28.6 (87) | 58.4 (76/76) | 19.0 (131) | 34.5 | 47.9 | 62.2 | 67.2 | 69.2 |
| qwen3.6-35b-a3b | 76 | 38.1 (75) | 13.4 (33) | 30.7 (47) | 62.9 (43/44) | 19.4 (76) | 38.2 | 51.1 | 63.9 | 67.1 | 68.2 |
| ling3-flash-vl-fp8 | 79 | not run | not run | 21.4 (41) | 52.7 (40/40) | 16.1 (79) | 30.3 | 35.7 | 60.2 | 62.9 | 63.4 |

The kraken column is over each route's Latin caps only (the bracket gives how many). "After" adds the cascade's
score on the caps to the sweep's whole-set NES, all 895 pages. Pooled by script:

| strata | ngram | half | second | kraken-ppocrv6 | ppocrv6 | retry first | readers first |
|---|---:|---:|---:|---:|---:|---:|---:|
| Latin (L1-L9) | 31.9 (811) | 11.0 (811) | 46.6 (851) | 63.3 (851) | 27.6 (851) | 34.3 (851) | 63.4 (851) |
| other scripts (N1-N6) | 23.7 (762) | 4.2 (762) | 27.3 (801) | – | 8.0 (801) | 24.3 (801) | 36.4 (801) |

## The 96 (the owner's truth pages)

| route | caps | ngram | half | second | kraken-ppocrv6 | ppocrv6 | bf16 vLLM | retry first | readers first |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| glm-ocr | 1 | 55.0 | 51.5 | 67.8 | 92.4 | 53.0 | – | 55.0 | 92.4 |
| lightonocr3-0.8b | 1 | 36.3 | 58.7 | 75.6 | 0.0 | 29.8 | – | 36.3 | 0.0 |
| paddleocr-vl1.5 | 11 | 58.4 | 23.0 (4/11) | 77.6 | 62.6 | 52.2 | – | 58.4 | 62.6 |
| qwen3-vl-8b | 1 | 46.5 | 56.9 | 67.1 | 55.2 | 53.2 | – | 46.5 | 55.2 |
| qwen3.5-4b | 1 | 25.5 | 0.0 (0/1) | 33.3 | 92.5 | 44.2 | – | 25.5 | 92.5 |
| Qwen3-VL 8B 4-bit, MLX on the Mac | 3 | 75.8 | 87.5 | 83.3 | 73.1 | 75.9 | 61.4 (2/3) | 75.8 | 73.1 |

The truth96 cluster caps were rerun as one sequential Sherlock job (`loop-rerun-seq.sh`); the MLX loops by
`loop_mac.py` with mlx-vlm's n-gram processor and at half size.

## Cost

Free cluster time and the Mac; nothing hosted. The cluster arms' span on one card, model load excluded
(`out/<route>/<arm>/summary.json`): n-gram 1.90 GPU-hours and half 6.12 GPU-hours for the 1,573 caps of nine routes;
per route in `loop-rerun-20261021.json` (`gpu_s`). Mean tokens a cap: n-gram 1,356, half 6,434, against 8,192 in the
sweep.

## Not run

Ling 3 Flash VL's two arms (four-GPU jobs, 79 caps) were cancelled by the owner after a size review on 2026-10-23:
the half arm had failed on all nine other readers, and n-gram, where scored by then, sat below kraken and the second
reader, so Ling's caps could not change the cascade, for up to 24-48 GPU-hours. Its second-reader, kraken and
PP-OCRv6 arms need no new calls and are in the tables. The six routes scored since show n-gram as a useful fallback
on the large readers' non-Latin caps (above), and Ling's second reader answers its 39 non-Latin caps poorly (12.5),
so n-gram might add something there; but at most about 39 pages × 20-25 points ÷ 895, under one point of Ling's
whole-set 60.2, on a cluster-only four-GPU reader that no profile recommends. Not refiled. Its inputs were on
Sherlock's $SCRATCH on 2026-10-23.

## Reproduce

Raw readings stay outside git, in `~/Claude/Long term storage/FarmShare-loop-rerun-20261021/runs/` (caps lists,
`routes.json`, the cluster's `out/` and `logs/`, `jobs*.tsv`, kraken texts). From
`ArchiveProcessor/scripts/segbench/corpus/`:

    ~/.local/bin/uv run --no-project --with regex,sacrebleu,numpy,rapidfuzz \
      python loop_rerun.py report --runs "$HOME/Claude/Long term storage/FarmShare-loop-rerun-20261021/runs" \
      --out ../../../segbench-results/bench-corpus

Cluster half: `loop-rerun-submit.sh`, `loop-rerun-job.sh`, `loop-rerun-seq.sh`, `loop_rerun_cluster.py`
(tests: `test_loop_rerun.py`). Three submissions were needed: the first pilot failed on an offline HF cache without
`refs/main`, the second on vLLM 0.31's V2 runner refusing the V1 n-gram processor (fixed with
`VLLM_USE_V2_MODEL_RUNNER=0` for that arm only).
