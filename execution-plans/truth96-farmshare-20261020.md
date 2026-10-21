# Truth96 FarmShare runs — submitted 2026-10-20

Owner request, 2026-10-20: "Queue the 96-page runs on FarmShare now." This is the missing half of "Both OCR sets,
every time" (root `CLAUDE.md`) for the models scored on the 895 public pages in Phase 0 of the processing review.
Free cluster time; no hosted API was called and no money was spent.

## What was submitted

Eight jobs on the `gpu` partition, submitted 21:37 PDT on 20 Oct (04:37 UTC on 21 Oct). They form one `afterany`
chain, so only one job holds GPUs at any time, as in the sweeps. A failed job releases the next one. Nothing retries
on its own.

| order | job | key | model | route | resources |
|---|---:|---|---|---|---|
| 1 | 1861696 | glm-ocr | zai-org/GLM-OCR | native `Text Recognition:` | 1 L40S, 8 CPU, 64 GB, 4 h |
| 2 | 1861697 | lightonocr3-08b | lightonai/LightOnOCR-3-0.8B | native, image only | same |
| 3 | 1861698 | lightonocr3-4b | lightonai/LightOnOCR-3-4B | native, image only, bf16 | same |
| 4 | 1861699 | paddleocr-vl15 | PaddlePaddle/PaddleOCR-VL-1.5 | native `OCR:` | same |
| 5 | 1861700 | qwen35-4b | Qwen/Qwen3.5-4B | panel prompt | same |
| 6 | 1861701 | qwen3-vl-8b | Qwen/Qwen3-VL-8B-Instruct | panel prompt | same |
| 7 | 1861702 | ppocrv6-medium-native | stock PP-OCRv6 medium det+rec | native pipeline | 1 L40S, 8 CPU, 48 GB, 2 h |
| 8 | 1861703 | ling3-flash-vl-fp8 | inclusionAI/Ling-3.0-flash-VL-fp8 | panel prompt | 1 node, 4 L40S, 16 CPU, 220 GB, 4 h |

**Qwen3-VL 8B was added.** Its existing 96-page runs are the hosted panel run (OpenRouter, Parasail bf16) and the
Mac 4-bit MLX run. The prompt, the 8192-token cap, temperature 0 and bf16 weights match the sweep. The serving
stack does not: neither run used the sweep's pinned snapshot or its vLLM 0.31.0 settings (one L40S, 16,384
context, bf16 KV cache, 0.90 memory, 16 sequences, concurrency 8). The FarmShare run costs about half an hour of one
GPU and gives a 96-page row on the same footing as its 895-page row.

## Pages and settings

- **Pages.** The 99 frozen truth-pack originals in `/home/users/cp1/fs-truthpack` (2400 px, JPEG 90, the bytes
  OpenRouter received), as every earlier FarmShare truth run read them: the 96 accuracy pages plus the three
  agreement-only letters p086, p094 and p096. The manifest `truth99.jsonl` is a copy of
  `interactive-20261018/ocr/owner99.jsonl`, the manifest CHURRO's owner run used. Layout checked all 99 images
  against `pack.json` (prompt sha `2ab7ab03…`) by SHA-256.
- **Pilot gate.** p001 (typewritten), p045 (handwritten table form) and p065 (printed table clipping). All three must
  finish with `stop` and a nonempty answer, or the model gets no full run. The full pass reuses the three pilot
  readings, so each model makes 99 calls.
- **Same settings as the 895.** Each model root holds its `prepared.json`, prompt file and frozen collector, copied
  from the sweep root, and that sweep's `cache-contract.json` as `sweep-contract.json`. The runner refuses to read
  unless its contract equals the sweep's in every field: revision, route, prompt and collector hashes, vLLM version,
  server arguments, cap, temperature, thinking off and concurrency. PP-OCRv6 checks its prepared models and
  `pipeline.yaml` against the 895 run's `contract.json`. A login-node preflight passed before submission.
- **Nothing in the 895 roots is written.** Weights, the vLLM environment and the PP-OCRv6 venv are read in place.
  Every output goes under the new root.

## Paths

- Remote root: `S=/scratch/users/cp1/fs-ocr/truth96-20261020`. Readings in `S/<key>/results/ocr/<key>/<page>.json`
  (PP-OCRv6: `S/ppocrv6-medium-native/raw/`). State in `S/<key>/status.json` and `pilot-summary.json`. Slurm logs
  in `S/logs/<job>-<key>.out`; vLLM logs in `S/<key>/logs/`. Receipt: `S/jobs.json`.
- Local receipt and recovery copy: `L=/Users/cp1/Claude/Long term storage/FarmShare-truth96-20261020`, with
  `jobs.json` (job IDs, the exact sbatch commands, resources, dependencies) and `recovery/` (the scripts run).
- Scripts in `recovery/`: `setup-truth96.sh` lays out the root, copying and checksumming only.
  `preflight-truth96.py` runs the static settings check. `submit-truth96.sh` submits the chain and refuses to run
  twice. `open-sweep-job.sh`, `open-sweep-multi-job.sh` and `ocr_run.py` are unchanged copies from the sweeps.
  `open_sweep_run.py` is the general sweep's runner, changed only to read `truth99.jsonl` and to require the
  contract match. `ppocrv6_run.py` and `ppocrv6_job.sh` are the 1860044 runner and job, changed only for the
  99-page manifest, the contract match and the reused venv and weights.

**At filing (21:40 PDT):** GLM-OCR 1861696 was running. Its contract matched the sweep's at run time, and its pilot
passed 3/3 with no caps, so it had moved on to the full 99. The other seven were waiting on their dependencies.

## Expected finish

At the 895-page rate, the single-GPU jobs total about 1.5 h with start-up. Ling takes about 1 h with its 15-minute
load. If GPUs free up as they did on 19–20 Oct, the chain ends around 00:30 PDT on 21 Oct. Ling needs a whole
4-GPU node and may wait longer for one. The latest possible end, if every job ran to its limit, is about 30 h after
submission.

## Collecting and scoring

1. Check `sacct -j 1861696,1861697,1861698,1861699,1861700,1861701,1861702,1861703 -X -o JobID,JobName%28,State,Elapsed`
   and each `S/<key>/status.json`. A completed VLM model reads `completed_raw` with `terminal: 99` and its counts.
   PP-OCRv6 writes `summary.json` with `raw_complete_review_pending`. Collect a failed model's partial readings too.
   Never resubmit inference on your own: the owner decides.
2. Copy `S` to `L/outputs/` with the `cm-farmshare` scp options from `farmshare-access.md`. The raw text stays
   outside git.
3. Score with the 96-page truth scorer that the earlier truth runs used: `ocr_panel_score.score()` against the pack
   truth (`ocr_panel.TRUTH/truth/<page>.txt` on the Mac). Aggregate as `cluster_ocr.py cmd_truth` does:
   `accuracy_96` without the three agreement letters, `agreement_3`, `clippings`, `all_99` and `throughput`. Read
   each record with `corpus/farmshare_expanded_report.reading()` in the model's mode: `native` for GLM-OCR,
   LightOnOCR and PaddleOCR-VL, `panel` for Qwen and Ling, `pipeline` for PP-OCRv6. Caps, blanks, errors and
   missing pages score as failures. No checked-in script turns these collector records into that summary yet. The
   collecting session writes a small one beside `farmshare_expanded_report.py` and checks it in.
4. Write `ArchiveProcessor/segbench-results/farmshare/truth/<key>-<job>/summary.json` and `pages.csv` in the shape
   of the existing runs. `env` needs `FS_PRESET` and `FS_VLLM_ARGS`, and `throughput` needs
   `pages_per_hour_per_gpu`, `gpus` and the mean token counts. Label the native routes as native, as on the 895.
   Add `PRESET_NAMES` entries in `ArchiveOCRBench/build.py` where needed.
5. ArchiveOCRBench update rule (root `CLAUDE.md`): commit the scored result and the rebuilt bench in the same commit.
   Run `python3 ArchiveOCRBench/build.py` and commit the built files. Only an interactive session republishes the
   page.
6. Tick the Phase 0 item in `processing-review/STATE.md` and delete this plan once the rows are on the bench.
