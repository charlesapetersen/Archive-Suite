# Institutional computing (Slurm)

Run the same OCR truth check and bulk reader on your institution’s GPU cluster, then import the resulting text
into Archive Processor with **Institutional computing**. The import matches image SHA-256, not filenames.
FarmShare is the first supported profile; Stanford access is not required to use the kit.

This kit supports **Slurm only**, NVIDIA GPUs, Python 3.10–3.13 and a compatible vLLM/CUDA installation. It runs
an OpenAI-compatible vLLM server on the allocated node’s loopback address and never exposes it to the network.
No paid API is called. The scholar transfers only material their institution permits to be processed there.

## Ask your research computing office

Ask for an account/allocation, SSH and transfer instructions, and whether your archival images may be held on
the service. Obtain these concrete settings before making a profile:

- Slurm partition, QOS (or an empty string for the default), charging account (or empty), maximum wall time,
  GPUs per node and per user, and running/submitted job limits. Confirm whether a job must request a typed
  GPU resource such as `gpu:a100:1`, and whether the partition mixes GPU models.
- GPU model, **memory per card** (24, 48 or 80 GB), NVIDIA driver/CUDA compatibility, and whether tensor
  parallel jobs can allocate multiple identical cards on one node. GPU capacity alone is not a quality score.
- Required Python/CUDA module names, how to initialize the `module` command in noninteractive batch shells,
  and whether to compile with a module toolkit or the matching toolkit installed beside PyTorch.
- Writable scratch and persistent storage paths, quotas, retention/purge periods, login-node installation and
  download rules, and whether compute nodes have network access. Check that enough host RAM can be requested
  too: the default requests `48 × GPUs + 32` GB. Ask how to revise `scheduler.sh` if that exceeds local policy.

For **PBS or LSF**, someone must implement and test equivalents of Slurm limits/association discovery
(`limits.py`), submission and resources/array arguments (`scheduler.sh`, `submit.sh`), job/array IDs and
requeue (`job.sbatch`, `train.sbatch`). A profile cannot translate a different scheduler; the loader refuses it.

## Make a cluster profile

Each `profiles/*.json` file holds the cluster’s display name, scheduler settings, GPU type and per-card
memory, modules/CUDA setup, scratch path, and persistent storage path, plus an optional CPU partition and QOS
(`slurm.cpu_partition`, `slurm.cpu_qos`) for a wave's score jobs. `farmshare.json` reflects FarmShare’s
reported 2026-10-15 limits; `example-university.json` is a **fictional**, offline-tested 80 GB H100 example, not a
claim about another university’s infrastructure. Copy either to a new file and replace every setting with
answers from your office. JSON is data, never shell code. Paths may use `$USER`, `$HOME` and other existing
environment variables; they must expand to absolute paths. Use an empty `gpu.gres_type` only if untyped
`--gres=gpu:N` reliably allocates the card named in your profile. Never infer memory from a mixed partition.

The `name` is the human-readable cluster name preserved as each page’s `_meta/*.json` `cluster` field and
shown by the app with model, precision and job ID. Give distinct clusters distinct names. Keep one checked-in
profile per cluster, without passwords, tokens or personal account secrets. The `slurm.account` field is
an allocation identifier, not a credential. A private profile file outside the checkout works too.

```bash
cd ArchiveProcessor/scripts/segbench/institutional-compute
python3 profiles.py example-university    # inspect quoted profile assignments, no cluster needed
bash submit.sh --profile example-university news auto --dry-run
bash setup.sh --profile farmshare         # on your login node; substitute your profile
bash download.sh auto                     # download the memory-appropriate checkpoint
```

`setup.sh` validates the selected partition/QOS against live Slurm, caps the profile’s limits to the observed
limits, checks writable scratch, loads modules and installs the venv. It writes ignored `compute.env` and
`limits.env`; real submissions require that setup profile. It does not silently select a different partition
or QOS. If your site hides association information, ask the office to help obtain it; do not guess an
allocation. Submission checks the profile’s content digest against setup’s snapshot. Run setup again after a profile or allocation change, with **no jobs using its venv**.

With `runtime.cuda_mode = "pip-toolkit"`, setup pins the NVIDIA compiler packages to PyTorch’s CUDA version
and the job uses that toolkit. With `"modules"`, the job loads your named modules and optional `cuda_home`;
you must select a toolkit compatible with the installed torch wheel. All job modes log the actual GPU and
runtime. `IC_VLLM_VERSION` can pin an approved vLLM release before setup.

`paths.scratch` holds the venv, Hugging Face cache, logs and runs beneath `institutional-compute/`.
`paths.storage` is a persistent destination created at setup; bulk output is an explicit `--out`, so copy
verified results there before scratch is purged. An offline dry-run creates **no directories**, downloads
nothing and never calls Slurm. Use it to review account, QOS, GPU type/count, wall time and path quoting.

## Presets by memory

| Memory per card | `auto` | Other options |
| --- | --- | --- |
| 24 GB | Qwen3-VL 8B, bf16, 1 GPU | GLM-OCR layout-first; 2×24 GB for the 27B fp8 preset |
| 48 GB | Qwen3.6 27B, fp8, 1 GPU | Qwen3.5 27B for segmentation; 4×48 GB for 122B fp8 |
| 80 GB | Qwen3.6 27B, fp8, 1 GPU | 27B bf16 with dynamic fp8 load; 4×80 GB for 122B fp8 |

Explicit presets retain their checkpoint/precision. `models.sh` computes a conservative power-of-two tensor
parallel count from the memory budget and submission refuses counts beyond node/user limits. Available
capacity is not permission to change a measured checkpoint. These are starting budgets, **not a promise of
fit or speed**: image count/context, KV cache, attention kernels and driver support also matter.
Memory does not imply FP8 support: confirm the selected checkpoint, quantization and KV format with the
office. The 80 GB example uses H100; an 80 GB A100 is not interchangeable for FP8 kernels. vLLM’s
[FP8 hardware requirements](https://github.com/vllm-project/vllm/blob/main/docs/features/quantization/llm_compressor/fp8.md)
distinguish Ada/Hopper/Blackwell W8A8 from Ampere’s W8A16 Marlin path. Prefer the bf16 `qwen3-vl-8b`
preset with `IC_KV_DTYPE=auto` when FP8 is unsupported, or an office-verified quantized checkpoint.
A successful dry-run proves submission arguments only, not CUDA kernel or model support. The 122B
preset uses a 192 GB budget; at 80 GB/card it rounds three cards up to four for tensor parallelism. Use a
smaller model if your node has only two. `IC_MAX_LEN`, `IC_GPU_UTIL`, `IC_KV_DTYPE` and `IC_MAX_SEQS` may tune
a trial; record their values and repeat the truth check after changing them. See the [FarmShare measured
runs](FARMSHARE_MEASUREMENTS.md) for the original precision-specific scores, not extrapolated local results.

## Truth check before bulk

First prepare the frozen truth pack **on the Mac** from the bench’s scratch inputs, transfer that pack to
your cluster, and run a bounded truth job before sending a large collection. The pack has the exact panel
prompt/images/truth and no source identity columns. Do not use the real corpus as a development input.

```bash
# On the Mac, from this kit directory:
python3 cluster_ocr.py pack --out /tmp/ic-truthpack
# Transfer /tmp/ic-truthpack to the cluster with your office’s approved transfer command.
# On the cluster, from the kit directory, after setup and download:
bash submit.sh truth auto --pack /scratch/$USER/ic-truthpack --hours 2 --dry-run
bash submit.sh truth auto --pack /scratch/$USER/ic-truthpack --hours 2
# Inspect runs/truth/<label>/summary.json, page scores/replies and logs under IC_ROOT.
```

Check every expected page answered, accuracy against the frozen truth, model/precision, actual GPU, CUDA and
vLLM startup errors, and measured pages/hour/GPU. A new institution’s throughput is **unmeasured** until this
job completes. Do not start bulk if truth is incomplete, quality is unsuitable, or allocation/storage is wrong.
For layout-first GLM-OCR run `bash setup.sh --layout` and `bash download.sh glm-ocr` before truth; for general
model newspaper comparison run `setup-layout.sh`, then `submit.sh news-layout PRESET`.

```bash
# --in contains scratch copies; --out must be outside it and fresh for this cluster/model/precision.
bash submit.sh bulk auto --in /scratch/$USER/pages --out /persistent/$USER/ocr-run --shards 1 --dry-run
bash submit.sh bulk auto --in /scratch/$USER/pages --out /persistent/$USER/ocr-run --shards 1
```

Bulk writes transcript text and `_meta` with image SHA-256, `cluster`, model, preset, vLLM arguments and Slurm
job; failed/looping/capped reads are logged for escalation. It drains 15 minutes before the wall limit and
requeues unfinished shards, bounded by `IC_CHAIN_MAX` (default 30). Resume reuses a transcript only when its
cluster, input digest, model and precision match. Missing or incompatible metadata refuses the run: choose a
new `--out` rather than relabel old text. Copy text **and** `_meta` back to a scratch folder on the Mac and
select **Institutional computing** in the app. No migration for older FarmShare metadata is provided because
nothing produced by these apps is retained. `cluster_ocr.py bulk` called directly requires `--cluster NAME`
or the profile’s exported `CLUSTER_NAME`.

## Waves: many jobs as dependency chains

A **wave** is a JSON file listing cluster jobs (`waves/example.json`). One short login-node step sends every
ready job as a chain of three Slurm jobs, each triggering the next, so the login session can end straight away:

```bash
python3 wave.py submit waves/my-wave.json --dry-run   # every sbatch command; no Slurm, no setup, nothing created
python3 wave.py submit waves/my-wave.json             # exit 3 if some job was not sent (not ready, or no room)
python3 wave.py status waves/my-wave.json
```

1. **Pilot**: the job's mode, preset and input on its first three items (`IC_LIMIT=3`), into its own folder,
   then a gate: all three must have been read (OCR modes: a parsed reply; seg: an answered window; text: a
   reply). A failed pilot cancels the rest of its chain. It is submitted held and released only once the whole
   chain has been accepted, so a refused submission never leaves a GPU job running that nothing will score.
2. **Full**: the whole run, `--dependency=afterok:<pilot>`. Bulk keeps its shards and its self-requeue.
3. **Score**: a small CPU job, `--dependency=afterany:<full>`, on the profile's `slurm.cpu_partition`. It waits
   for any requeued bulk shard, runs the job's own `score` argv if it has one (placeholders `{full}`, `{pilot}`,
   `{results}`, `{wave_dir}`), and copies the run's small files (summaries, `pages.csv`, throughput, failure and
   escalation logs; never transcripts, replies or images) into `results/<id>/` with a `status.json`.

Each job's files live under `$IC_ROOT/waves/<wave>/<id>/`, and only **`$IC_ROOT/waves/<wave>/results/`** needs to
come back to the Mac. A job is ready when its input is on the cluster (the pack's index file, a bulk folder
holding an image, NewsBench); `submit` skips a job that already has a chain and stops at the profile's
submitted-job limit, so run it again as input arrives or jobs finish. Job fields: `id`, `mode` (`truth`, `seg`,
`text`, `news`, `bulk`; `news-layout` has no pilot), `preset`, `pack` or `in`/`out`/`shards`, `hours`,
`pilot_hours` (default 1), `score_hours` (default 1), `env` (extra `IC_*` settings) and `score`. Paths may use
`$IC_ROOT`, `$USER` and `$HOME`. The CPU partition is taken from the profile without a live check; a wrong one
is refused at submission, before the pilot is released. The chain is tested offline against a pretend Slurm
(`test_institutional_compute.Wave`); no real wave has run yet.

Other modes remain available: `cluster_seg.py` packs/runs/imports segmentation windows; `cluster_text.py`
sends exported text prompts; `train_seg.py` and `train.sbatch` train/merge students. Training is manually
submitted with the same profile’s scheduler caps and exported runtime snapshot:

```bash
source compute.env; source limits.env; source scheduler.sh
# First install the training venv with setup-train.sh, directly only if login-node policy permits.
# For a CPU installation job, obtain its partition/QOS/account from your office (the GPU profile cannot infer it).
export TRAIN_DATA=/scratch/$USER/training TRAIN_MODEL=Qwen/Qwen3.5-4B TRAIN_OUT=/scratch/$USER/student
export IC_GPUS=1 IC_MODE=seg-train
export IC_WALL_MIN=$((IC_MAXWALL_MIN < 480 ? IC_MAXWALL_MIN : 480))
slurm_args
printf '%q ' sbatch --export=ALL "${SBATCH_ARGS[@]}" train.sbatch; printf '\n'
# Inspect the printed command, then submit:
sbatch --export=ALL "${SBATCH_ARGS[@]}" train.sbatch
```

Confirm that one profile GPU fits the chosen training model and that the wall limit is sufficient; training
has different memory needs from serving. Queued jobs use the submitted environment snapshot, so later setup
cannot rename their provenance. Never modify an in-use venv. The old FarmShare hand-run examples in the
measured notes are a record of those jobs. Historical `fs-*` bench method keys and
`segbench-results/farmshare/` results stay named for the actual measurement source.

## Institution-hosted model endpoints

An institution may already host an **OpenAI-compatible** vision model. The app’s existing **API Gateway**
route reaches it: leave **A model on this Mac** off, set its base URL (for example
`https://models.example.edu/v1`; the app appends `/chat/completions`), exact model ID and gateway token.
Tokens are saved in Keychain; no new provider route is needed. Ask the office for network/VPN access, model,
quota/concurrency limits and approved data handling. The app sends `Authorization: Bearer <token>`; browser
SSO or custom authentication headers need an institutional proxy. If the endpoint ignores authentication,
the office can provide an approved nonempty placeholder, since the app requires a key field.

The endpoint must accept chat `messages` with inline `image_url.url` JPEG data URLs and text, and return
unstreamed `choices[0].message.content` as a string. OCR normally uses max edge 2,048 and up to 8,192 output
tokens with a 120-second request timeout. Confirm supported context/image/output limits, including context
images; select a nonreasoning model or have the server disable reasoning. Gateway batch processing and LLM
rotation are not supported. This route reads pages directly; it does not require bulk import or this kit.

## Offline verification

```bash
python3 -m unittest test_institutional_compute
```

Tests use synthetic scratch images and a fake localhost vLLM server, validate both profiles and 24/48/80 GB
preset sizing, exercise `submit.sh --dry-run` without setup or Slurm, and verify that cached transcripts cannot
be attributed to a different cluster. No cluster jobs, real corpus or money are involved.
