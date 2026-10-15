# FarmShare: the open-weight candidate and a ready job (W41.farmshare-plan)

Question 4 of the W41 bake-off: could Stanford's FarmShare GPUs read the whole corpus with an open-weight model,
and how long would it take? This folder holds the answer from the panels and a Slurm job that is ready to run.
**Nothing here has run on FarmShare.** Logging in needs the owner's SUNet ID and two-step authentication, so
the run is `W41.farmshare-run`, the owner's step. Every pages-an-hour figure below is an **estimate**. The job
measures the real one.

## The candidate: Qwen3.6 27B at fp8 on one L40S

| | Qwen3.6 27B fp8 | Qwen3.6 35B-A3B fp8 | Qwen3-VL 8B bf16 |
|---|---:|---:|---:|
| NES, 96 accuracy pages (OpenRouter) | **94.28** (95/96 completed) | 93.02 (96/96) | 91.81 (94/96) |
| NES, 13 clippings pages | 93.71 | 91.92 | 93.47 |
| words missed | 3.36% | 2.07% | 3.65% |
| fits one 48 GB L40S | yes, about 29 GB of weights | yes, about 36 GB, a tighter KV cache | yes, 18 GB |
| estimated photos an hour per GPU | 760-1,816 | 2,115-4,822 | 1,090-2,559 |

The comparison points are Gemini 3.1 Flash-Lite, the app's default, at 91.61 and Claude Sonnet 5.5, the best on
the cloud panel, at 96.47.

- **Qwen3.6 27B is the first choice.** It is the best open-weight reader measured anywhere in W41, and it is above
  both open-weight cloud giants on the same pages: Qwen3-VL 235B scored 93.95 and Qwen3.5 397B 93.98. It is also
  above the app's default Flash-Lite. The panel served it at fp8 on Chutes, and the official `Qwen/Qwen3.6-27B-FP8`
  checkpoint is fp8 too. The two are not necessarily the same build, so the truth run measures the score FarmShare
  actually gets.
- **Qwen3.6 35B-A3B is the speed option.** It has 3B active parameters, so it is estimated at about 2.5-3 times the
  pages an hour for 1.3 points of NES. It is also the panel's lowest words-missed rate, 2.07%.
- **Qwen3-VL 8B is the floor.** It is the only candidate the job runs at exactly the precision OpenRouter measured
  (bf16).
- **Segmentation:** `Qwen/Qwen3.5-27B-FP8` (preset `qwen3.5-27b`). It got 95.0% of pages into the exact document on
  Deaver at fp8 (W41.seg-large), and it fits the same card. The preset serves it, but the segmentation windows and
  their assembly (`method_openrouter.py`) are not wired to a local server yet. That is the only part of the item
  that is not ready to run. Its OCR row reads 81.80 only because SiliconFlow failed 14 pages. On the pages it
  completed it scored 95.76.

### Why not the whole four-card node (192 GB)

The node is not worth it, for these reasons:

- **The giants don't fit.** Qwen3-VL 235B at fp8 is about 240 GB. Qwen3.5 397B is too big even at 4 bits: 397B
  parameters at half a byte each is about 200 GB, by arithmetic, not a measured download.
- **The 235B would need llama.cpp.** It fits only as a 4-bit GGUF, at about 140 GB, and on the cloud panel it
  already scored below the 27B at fp8.
- **The model that fits scored worse where it was measured.** That model is Qwen3.5 122B-A10B at fp8, about 126 GB.
  Its OCR is unmeasured, and on segmentation it scored 84.4%, below the 27B's 95.0%.

On these panels, bigger has not been better. Four copies of the 27B, one per card, would read about four times as
fast and score higher. A `qwen3.5-122b-a10b` preset is still included, so that one truth run can settle "bigger?"
on FarmShare's own hardware.

## Estimated GPU time (`estimate.py`)

| candidate | panel NES | photos/h/GPU | GPU-h per 100k photos | newspaper pages/h/GPU | GPU-h per 100k newspaper pages |
|---|---:|---:|---:|---:|---:|
| Qwen3.6 27B fp8 (1 GPU) | 94.28 | 760-1,816 | 55-132 | 217-585 | 171-461 |
| Qwen3.6 35B-A3B fp8 (1 GPU) | 93.02 | 2,115-4,822 | 21-47 | 297-453 | 221-337 |
| Qwen3-VL 8B bf16 (1 GPU) | 91.81 | 1,090-2,559 | 39-92 | 322-923 | 108-311 |
| Qwen3.5 27B fp8 (1 GPU; segmentation) | 81.80* | 760-1,816 | 55-132 | 217-585 | 171-461 |
| Qwen3.5 122B-A10B fp8 (4 GPUs) | unmeasured | 715-1,419 | 70-140 | 91-133 | 751-1,098 |

\* 82/96 pages completed. On the pages it completed it scored 95.76.

**How the figures are made.** Each page's cost comes from the parameter count and L40S datasheet figures: 362 TFLOPS
at fp8, 181 at bf16, 864 GB/s of memory bandwidth. The page itself is the token counts measured on the panels'
OpenRouter replies:

- photo pages: 4,573 image tokens (Qwen's processor at the 2400 px cap) and about 460 output tokens;
- newspaper pages: about 10,000 image tokens at a 3584 px cap and about 4,900 output tokens. This one is not
  measured. It comes from NewsBench's mean of 3,603 words a page.

The range runs from 20% to 40% of peak compute, with prefill and decode either serial or overlapped. Two things
are not modelled: KV-cache limits on long newspaper pages, and time spent loading images.

**At corpus scale.** 100,000 photos with Qwen3.6 27B is about 55-132 GPU-hours. The FarmShare docs give 4 running
GPU jobs per user, so that is roughly 14-33 hours of wall time. This is the limit to confirm on the cluster.

## Newspapers

There are two kinds of newspaper material, and they are scored differently:

- **Clippings in the archive photos** are the 13-page clippings stratum of the truth set, in the first table above.
  The truth run reports it separately (`summary.json` → `clippings`).
- **Full broadsheet pages** are scored on NewsBench, which is what the Vision OCR lab's newspaper truth turned out to
  be. It has 19 Library of Congress pages, 15 of them with whole-page gold. The scans are public domain and the
  text is CC0. The gold was transcribed by volunteers, not by us. Its own `score.py` gives "overall" = 1 − CER
  (lowercased alphanumerics, order-sensitive). `news` mode writes the `ocr-results/<label>/<id>.txt` files that
  scorer reads, and computes the panel's NES as well.

The Vision OCR lab's table (`~/Claude/vision-ocr/OCR-NEWSBENCH-2026-10-07.tsv`) already gives the expected picture.
Whole-page vision-language models land around 0.75-0.82 overall: Qwen3-VL 8B at 4-bit 0.752, Gemini 3.5 Flash-Lite
0.820. Layout detection followed by GLM-OCR on each region scores 0.970. **So for broadsheets the strongest FarmShare
route is probably layout-first, not a bigger whole-page model.** That pipeline is not in this job. It is filed as
`W41.farmshare-news-layout`, and it waits on the run, because it is only worth building if the owner uses FarmShare.

## FarmShare's limits (read on the cluster, not assumed)

This is what the docs said on 2026-10-15 (docs.farmshare.stanford.edu, read through a fetch summary):

- **Hardware:** 6 GPU nodes ("oat"), each with 4 NVIDIA L40S.
- **Queue:** partition `gpu`. The `gpu` QOS allows 6 GPUs, 4 running jobs and 32 submitted jobs per user. The
  `normal` QOS allows 3 GPUs.
- **Software and storage:** Apptainer, conda and modules on Ubuntu 24.04, plus a global `/scratch`.
- **Terms:** FarmShare is for coursework and research, *not for sponsored research or high-risk data*. Whether this
  project qualifies is the owner's call (W41.farmshare-run).

The docs give no wall-time limit for the GPU QOS and no scratch quota. `limits.py` asks Slurm (`sinfo`,
`sacctmgr`), `df` and `quota` instead. It writes `limits.env`, and `submit.sh` fits every job to it: partition,
QOS, GPUs, `--time`, and the number of bulk shards.

## Running it (W41.farmshare-run, the owner)

1. **On the Mac:** `python3 fs_ocr.py pack --out /tmp/fs-truthpack`, run from this folder. It needs Pillow. The
   pack holds the 99 frozen truth images, byte-identical to what OpenRouter received, plus their truth text and
   the non-identifying strata. It is 74 MB.
2. `ssh <sunet>@login.farmshare.stanford.edu` (two-step), then
   `git clone https://github.com/charlesapetersen/Archive-Suite.git`, then
   `scp -r /tmp/fs-truthpack <sunet>@login.farmshare.stanford.edu:`.
3. In `Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/`:
   ```bash
   bash setup.sh                         # limits.env + venv (vLLM, scorer deps) on scratch
   bash download.sh qwen3.6-27b          # ~31 GB into $HF_HOME on scratch
   bash submit.sh truth qwen3.6-27b --pack ~/fs-truthpack
   bash submit.sh news  qwen3.6-27b      # clones NewsBench at the lab's commit, on the login node
   ```
   Watch the job with `squeue -u $USER`. Its log is in `$FS_ROOT/logs/`.
4. **Bring back** `$FS_ROOT/runs/{truth,news}/<label>/summary.json` and `pages.csv`. Those two hold scores,
   token counts and timings, and no transcript text. `summary.json` → `throughput.pages_per_hour_per_gpu` is the
   measured figure that replaces the estimate. Its `env` records the vLLM version, the node and the GPU.
5. **If the FP8 checkpoint will not load on Ada** (an error about block-quantised fp8 kernels), use the
   `qwen3.6-27b-dyn` preset. It loads bf16 weights (56 GB) and quantises them to fp8 at load time.

**Bulk:** `bash submit.sh bulk qwen3.6-27b --in DIR --out DIR`.

- **Input:** a directory tree of images. Exporting page images from the corpus PDFs is a separate step.
- **Output:** one `.txt` per page, mirroring the input tree. Each page also gets `_meta/<page>.json` with kind,
  table, tokens and timing.
- **Shards:** one shard per allowed GPU job.
- **Ending a job:** each job stops sending pages 15 minutes before its wall limit. It then queues its own shard
  again, up to 30 times.
- **Done pages** (their `.txt` exists) are never read twice.
- **Failures** go to `failed-<shard>.jsonl`. Running `submit.sh` again retries them.
- `--out` must be outside `--in`. The input is only ever read.

## Files

| file | what |
|---|---|
| `fs_ocr.py` | `pack` (Mac), `truth`, `news`, `bulk`. Imports the panel's `PROMPT`, image cap and `max_tokens`, so a FarmShare row is the panel's measurement at FarmShare's precision |
| `limits.py` | reads the cluster's limits and writes `limits.env` |
| `models.sh` | presets: Hugging Face repo, GPUs, download size, vLLM flags |
| `setup.sh`, `download.sh`, `submit.sh`, `job.sbatch` | environment, weights, fitted submission, and the GPU job that serves vLLM on localhost and runs one mode |
| `estimate.py` | the estimate table above |
| `test_farmshare.py` | offline tests: Slurm parsing, and the driver against a fake vLLM server |
