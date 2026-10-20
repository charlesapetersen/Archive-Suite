# Inkling Small alternative runtime — checkpoint, 2026-10-19

W43.inkling-farmshare. Owner asked whether an obvious way exists to run Inkling Small. The earlier rejection
was specifically the installed vLLM/Ada custom-attention path. A ready contributor branch of llama.cpp supports
Inkling images, and Unsloth supplies a matching multimodal GGUF. This is a bounded alternative-runtime attempt,
not a claim that image inference already works on FarmShare. Existing shared environments/jobs stay unchanged.

## Submitted work — never duplicate

- **1857687**:8CPU/64GB/2h incremental link then pinned download. Build reached100% successfully; GGUF files now downloading.
- **1857671**:one node/4 L40S/16CPU/220GB/12h, afterany1857687 AND1857668 (Nemotron, last general-model job).
  This is the same GPU ID from initial submission; only failed CPU build dependencies were corrected.
- Prior CPU-only1857670/1857673/1857674 failed in CMake configuration, before model downloads or inference.
  Their logs remain. Versioned pip CUDA runtime/static paths and a missing CPU-node driver development stub
  were fixed. Job1857675 later failed only at final executable linking; the SDK stub SONAME symlink and build-only -rpath-link now resolve that dependency. Incremental1857687 reuses compiled objects and has linked successfully. No GPU inference was duplicated. Do not resubmit because one old setup receipt says FAILED.

L=`/Users/cp1/Claude/Long term storage/FarmShare-inkling-20261019`
S=`/scratch/users/cp1/fs-ocr/inkling-20261019`
Read L/jobs.json and collection-status.json, then scheduler and S/logs. Restored collector log collection-restored.log;
prior collector status/markers remain archived after reloading the corrected setup ID. A48h non-LLM caffeinate
collector polls180s, retrieves the terminal GPU model root (success or failed partials) to L/outputs and all logs
to L/remote-logs, and exits. It never submits/retries inference/authenticates/starts a daemon. SSH master retained.

## Exact alternative and boundaries

[Unsloth GGUF](https://huggingface.co/unsloth/Inkling-Small-GGUF), revision
1a19ef82883cb7b9c581b93c30ea252dabbf658d. Five UD-Q4_K_M shards plus mmproj-BF16.gguf,
162,676,291,520 bytes together. Different quantization/runtime from official NVFP4; keep rows and timings labelled.
[Inkling support PR25731](https://github.com/ggml-org/llama.cpp/pull/25731) explicitly includes vision/audio;
**unmerged**, pinned danielhanchen/llama.cpp SHA534c32182487ee3277908a91dd02f6d8e8ac7ed4. No moving master build.
No kernel implementation is being written here. Binary compiled for SM89 only; source/build isolated at S/src and S/build.
Build script first compiles llama-server, then downloads only the pinned six GGUF files. Metadata refuses gated
or changed revisions and weights exceeding175GB; prepared.json appears only after complete preparation.

CPU nodes have no NVIDIA driver, so the build uses the development stub from NVIDIA's official1.49MB
CUDA13.0.96 archive, SHA25b8071951baba827be1580b841d363464f6ee6c39f48d33a81646f90cc95ed1.
The archive is retained at L/recovery and S/recovery; exact source URL/checksum in evidence JSON. Extract only
lib/stubs/libcuda.so into S/cuda-stub. **Build-only**: no driver installation, no stub runtime library path;
CMAKE_SKIP_RPATH=ON and GPU LD_LIBRARY_PATH point to actual build/bin + installed CUDA libs. Shared pip CUDA
and vLLM environments are not patched. Uncompiled source and failed logs remain available for explicit recovery.

GPU uses llama-server with matching projector, localhost only, layer split1/1/1/1, all possible layers on GPU,
context16384/parallel1/output8192/temp0/seed0/Jinja/reasoning-budget0. --fit on with fit-ctx16384 retains context
and reserves1024MiB/device; may place some layers on CPU to fit, which must be reported from logs. No silent
precision reduction, context shrinking or replacement model. Startup bounded20min; job bounded12h. If timeout,
keep raw cache and checkpoint instead of pretending the895 pages finished or automatically retrying.

Same checked895 frozen JPEGs and L1/L4/L8 three-page pilot as previous batches. All three must answer nonempty,
uncapped stop before full; full reuses those three. Frozen legacy collector SHA unchanged. API caps/errors retained,
no automatic cap/failed-page retry. Cache binds prompt/image identity, model revision, runtime source+binary hash,
server settings and decoding independently of manifest length. Source scripts under corpus/inkling-gguf-*.sh and
open_sweep_run.py; durable deployed copies at L/S recovery, no temporary-worktree references.

## Resume and finish

Do not start another collector until checking existing marker/PID/status. If build fails, inspect the current
1857687 log; a GPU skip from missing prepared.json preserves the chain. No additional setup or inference retry
is silently authorized by collection. On pass, review real image transcription/prompt/thinking behavior before
accepting scores; nonempty pilot output is a compatibility gate, not a quality judgment. Score saved895 raw
answers, failures as failures, separately from historical440 and other precision/runtime routes. Update numeric
report/ArchiveOCRBench after review; no automatic catalogue/default/adoption change. Reconcile shared TODO/DONE
and primary plan, delete this plan only when reviewed results are shipped. Manager reads trackers/Git/plan;
interactive provenance retained, no fabricated daemon engine ledger, grants or usage. No hosted money spent.


## SSH restored —19Oct recovery

Owner reopened the login; preflight reached rice-02 as cp1. All four stopped task-owned collectors were checked
not running, old markers/status/access blocker archived under each L/ssh-recovery-<UTC>, and collectors restarted.
The original extension collector retains previously validated collected IDs; the three sweep collectors had
retrieved nothing before the outage. Current logs collection-restored.log. The restored collector uses the
current jobs.json with setup1857687/GPU1857671. SSH timeout now includes a3s forced cleanup after the15s bound;
no auth fallback or automatic reconnect. The old owner-login blocker is resolved, not a reason to resubmit jobs.

Two original OCR extensions completed0 (Qwen3.6 27B and35B-A3B); Qwen3.5 27B still running at recovery.
Ling/Nemotron preparation1857666 completed0, both pinned model roots ready. Existing inference IDs/dependency
chain retained; no repeated model calls. Inkling CUDA final linking completed100%; model download remains active.
The real image pilot and895-page result review remain pending. Continue from recorded jobs and raw caches only.

## PARKED — 2026-10-20 (owner decision; do not resubmit or run the full set)

**Final state of this route: pilot only, run not completed, parked on purpose.**

- 1857671 failed in 19 s at 06:01 on 20 Oct: `llama-server` reported `libllama-server-impl.so` not found. The
  library existed and the job's `LD_LIBRARY_PATH` resolved it when reproduced on the login node, so the cause was
  not established. `recovery/inkling-gguf-job.sh` now writes an `ldd` dump to
  `inkling-small-gguf-q4/logs/ldd-<job>.txt` (original: `inkling-gguf-job.sh.orig-1857671`).
- Resubmitted by hand as **1860045** (4 GPUs, 12 h, no dependency). The `ldd` dump shows the library resolving and
  the server answered, so the original error did not recur. The three-page pilot ran in 226 s: 2 ok, 1 cap
  (`si__NMAAHC-007630087_00342`, a handwritten page that ran to the 8192-token cap, about 23,000 characters).
  `recovery/open_sweep_run.py` stops on any capped pilot page ("Pilot failed (capped/empty answer); no full run"),
  so 1860045 exited FAILED after 6 min 53 s without reading the 895 pages. Temperature 0 and seed 0 mean a rerun
  would reuse the cached capped reading.
- **Why parked.** This is not the real model. It is a community 4-bit quantisation (`unsloth/Inkling-Small-GGUF`,
  UD-Q4_K_M) on a llama.cpp build from an unmerged support branch (`support_pr_merged: false`), run one request at a
  time with reasoning off. Ling3 and Nemotron are also quantised but are the publishers' own checkpoints on vLLM's
  supported path. A score here would mix quantisation, runtime and unreleased model support, and the capped page
  looks like a repetition loop of that kind. A full run would need up to 12 h of 4 GPUs for a number that cannot be
  compared fairly. The owner chose to leave it.
- **Record Inkling as:** Q4 GGUF on unmerged llama.cpp, three-page pilot 2 ok / 1 cap, run not completed. No
  score. Revisit only with a faithful setup (original weights on a runtime that officially supports them), which
  has not been looked for.
