# FarmShare: the open-weight candidate and a ready job (W41.farmshare-plan)

Question 4 of the W41 bake-off: could Stanford's FarmShare GPUs read the whole corpus with an open-weight model,
and how long would it take? This folder holds the answer from the panels and a Slurm job that is ready to run.
The owner ran it on 2026-10-15 (`W41.farmshare-run`); the measured figures are in the next section, and the
sections after it are the plan as written before the run, with its estimates.

## Measured on FarmShare (2026-10-15)

One L40S per run, vLLM 0.31.0, the 99 frozen truth pages from `fs_ocr.py pack`, scored as the panel scores.
Results: [`segbench-results/farmshare/`](../../../segbench-results/farmshare/) (`summary.json` and `pages.csv` per
run, no transcript text).

| run | NES, 96 accuracy pages | answered | NES, 13 clippings | photos an hour per GPU |
|---|---:|---:|---:|---:|
| **`qwen3.6-27b`, fp8 KV cache (the default)** | **95.25** | 96/96 | 93.51 | **1,055** |
| `qwen3.6-27b`, `FS_KV_DTYPE=auto` (bf16 KV cache) | 94.97 | 96/96 | | 903 |
| `qwen3.6-27b-dyn`, fp8 KV cache | 93.17 | 94/96 | 93.60 | 649 |
| the panel's hosted run (Chutes fp8, for comparison) | 94.28 | 95/96 | 93.71 | |

- **The default is the one to use.** It answered every page and reads as well as the hosted run did on the pages
  that one answered (95.27 completed-only). The bf16 KV cache is 14% slower for no gain. The `-dyn` preset is
  slower still, and two pages (p053, p054) ran to the 8,192-token cap, which looks like looping; on the pages it
  answered it scored about 95.2.
- **At corpus scale:** 1,055 photos an hour is about 95 GPU-hours per 100,000 photos, inside the estimate of
  55-132. The cluster allows 4 GPUs at once per user, so about a day of wall time.
- **Newspapers, whole page** (`news`, NewsBench's 15 scored pages, its own `score.py`): **0.967 overall** (0.994
  broadsheet, 0.949 page), against 0.970 for the best layout pipelines (`ll-doclayout-pvl`, `glm-ocr-doclayout`)
  and 0.20-0.50 for the other whole-page models in the lab's table. Panel NES on the same pages 95.91. Two of the
  19 pages ran to the 16,384-token cap (neither is among the 15 scored), and a page takes about 55 seconds:
  65 newspaper pages an hour per GPU. Full table: `segbench-results/farmshare/news/newsbench-score.txt`.

What it took to get there, all fixed in this folder: `limits.py` paired the `normal` partition with the `gpu` QOS,
which `normal` refuses; `download.sh` passed three patterns to one `--exclude`, which `hf` 1.x reads as file
names, so it fetched nothing; and FlashInfer compiles attention kernels at start-up with `nvcc`, which the GPU
nodes lack. FarmShare's `cuda/12.9.0` module is the wrong one, since vLLM's torch is built for CUDA 13, so the job
uses the CUDA 13 toolkit in the venv (`setup.sh` pins its compiler to torch's version; `job.sbatch` sets
`CUDA_HOME` and the link paths).

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
route is probably layout-first, not a bigger whole-page model.** That was the plan as written; the next two
paragraphs are what the run measured and the layout route that was built after it.

**The run changed this (2026-10-15).** Qwen3.6 27B whole-page scored 0.967 overall, level with layout-first (0.970)
and well above every whole-page model in the lab's table. Layout-first still leads on the "page" measure (0.968
against 0.949) and cannot run into the output cap that cost two pages here, so it remains worth measuring, as a
comparison rather than a presumed win.

### The layout-first route (`glm-ocr` preset, W41.farmshare-news-layout)

Built 2026-10-15; **not yet run on FarmShare** (that needs the owner's login, `W41.farmshare-news-layout-run`).
`news_layout.py` runs the pipeline behind NewsBench's 0.970 row (`glm-ocr-doclayout`): the
[`newspaper-ocr`](https://github.com/nealcaren/newspaper-ocr) library, version 0.11.0, with its defaults,
DocLayout-YOLO (the 1280 DocStructBench checkpoint) finding the regions and GLM-OCR (0.9B) reading each one, in the
library's reading order. The library's own docstring gives the figure: DocLayout-YOLO + GLM-OCR 0.970, PaddleX +
GLM-OCR 0.937. Two things differ from the measured run, and both are about speed:

- **GLM-OCR is served by vLLM** on the same GPU (the library's `api` mode), instead of loaded into transformers.
  NewsBench's notes give about 90 s a page that way on an L40S. vLLM applies the checkpoint's own generation
  defaults, as `generate()` did, and the preset turns on the MTP speculative decoding the vLLM recipe for GLM-OCR
  gives (`FS_GLM_MTP=0` turns it off if it will not start).
- **A page's regions go to the server at once** (about 67 a page on NewsBench), through the library's
  `recognize_regions` hook, up to 48 in flight; 4 pages are in flight, and detection takes one page at a time.
  Each region still goes through the library's own retries, code-fence strip and repetition check.

The preset sets `FS_LAYOUT=1`, so every mode reads layout-first: `news` scores it on NewsBench as above,
`bulk` reads a tree of newspaper page images at full resolution (the same resume, shards, deadline and dead-server
rules; a page where some regions got no answer is logged as `partial` and read again by the next run), and `truth`
works too, which gives a clippings figure beside the whole-page one. Pages an hour come out of `summary.json` as
before; the token counts are empty, since the library does not report them.

```bash
bash setup.sh --layout                # once, no job queued: newspaper-ocr + DocLayout-YOLO into the venv
bash download.sh glm-ocr              # ~3 GB: GLM-OCR and the detector checkpoint
bash submit.sh news glm-ocr           # NewsBench: then its score.py, as for the whole-page run
bash submit.sh bulk glm-ocr --in DIR --out DIR
```

`setup.sh --layout` pins every package already in the venv at its installed version, so it adds the library around
vLLM or stops with a conflict; it never changes what the measured runs used. If it stops, the fix is a separate
venv for the reader (vLLM is only reached over HTTP), not loosening the pins. Untried on the cluster, and so open:
whether vLLM 0.31.0 serves GLM-OCR with MTP, and whether the detector fits in the 20% of the card the preset leaves.

## FarmShare's limits (read on the cluster, not assumed)

This is what the docs said on 2026-10-15 (docs.farmshare.stanford.edu, read through a fetch summary):

- **Hardware:** 6 GPU nodes ("oat"), each with 4 NVIDIA L40S.
- **Queue:** partition `gpu`. The `gpu` QOS allows 6 GPUs, 4 running jobs and 32 submitted jobs per user. The
  `normal` QOS allows 3 GPUs.
- **Software and storage:** Apptainer, conda and modules on Ubuntu 24.04, plus a global `/scratch`.
- **Terms:** FarmShare is for coursework and research, *not for sponsored research or high-risk data*. Whether this
  project qualifies is the owner's call (W41.farmshare-run).

The docs give no wall-time limit for the GPU QOS and no scratch quota. The cluster itself reported, on 2026-10-15:
the `gpu` QOS at 4 GPUs and 4 running jobs per user, `normal` at 1 GPU, a 2-day partition limit, and GPU nodes in
both the `normal` and `gpu` partitions, with `normal` refusing the `gpu` QOS. `limits.py` asks Slurm (`sinfo`,
`sacctmgr`, `scontrol` for each partition's allowed QOS), `df` and `quota` instead. It writes `limits.env`, and `submit.sh` fits every job to it: partition,
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
   `qwen3.6-27b-dyn` preset. It loads bf16 weights (56 GB) and quantises them to fp8 at load time. If vLLM will
   not use an fp8 KV cache with Qwen3.5/3.6's hybrid attention, run with `FS_KV_DTYPE=auto`. Neither was needed on
   2026-10-15: the FP8 checkpoint loaded (weight-only fp8 through Marlin, since Ada has no block-fp8 kernels), and
   both measured slower than the default. A start-up failure that names `nvcc`, `libcudart.so.12`, "headers are
   incompatible" or "Unsupported .version" is the CUDA toolkit, not these; see the paragraph above the plan.
   Don't run `setup.sh` again while a job is queued: a job that starts while pip is swapping the compiler mixes
   two CUDA versions and fails.

**Bulk:** `bash submit.sh bulk qwen3.6-27b --in DIR --out DIR` (newspaper pages: the `glm-ocr` preset, above).

- **Input:** a directory tree of images. Exporting page images from the corpus PDFs is a separate step.
- **Output:** one text file per page, named after the image (`box1/a.jpg` → `box1/a.jpg.txt`), mirroring the
  input tree. Each page also gets `_meta/<image>.json` with kind, table, tokens and timing.
- **Shards:** one shard per allowed GPU job. Pages are assigned by a hash of their path, so adding files mid-run
  cannot leave a page in no shard.
- **A dead server:** if eight reads in a row get no answer (vLLM crashed, say), the job stops and queues itself
  again. Pages that got no answer count as still to do.
- **Ending a job:** each job stops sending pages 15 minutes before its wall limit. It then queues its own shard
  again, up to 30 times.
- **Done pages** (their `.txt` exists) are never read twice.
- **Failures** go to `failed-<shard>.jsonl`: a reply cut off or unparseable, a request the server refused, or an
  image Pillow cannot open. They never stop the run. Running `submit.sh` again retries them.
- `--out` must be outside `--in`. The input is only ever read.

## Files

| file | what |
|---|---|
| `fs_ocr.py` | `pack` (Mac), `truth`, `news`, `bulk`. Imports the panel's `PROMPT`, image cap and `max_tokens`, so a FarmShare row is the panel's measurement at FarmShare's precision. `--layout` reads with `news_layout.py` instead |
| `news_layout.py` | the layout-first reader: `newspaper-ocr`'s DocLayout-YOLO + GLM-OCR pipeline against the local vLLM server |
| `limits.py` | reads the cluster's limits and writes `limits.env` |
| `models.sh` | presets: Hugging Face repo, GPUs, download size, vLLM flags |
| `setup.sh`, `download.sh`, `submit.sh`, `job.sbatch` | environment, weights, fitted submission, and the GPU job that serves vLLM on localhost and runs one mode |
| `estimate.py` | the estimate table above |
| `test_farmshare.py` | 20 offline tests: Slurm parsing, presets, the driver against a fake vLLM server (resume, shards, deadline, dead server, unreadable images, truth scoring), and the layout route with the real library against a fake GLM-OCR server and detector (skipped where `newspaper-ocr` is not installed) |
