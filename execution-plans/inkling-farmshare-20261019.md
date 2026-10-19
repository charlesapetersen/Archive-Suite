# Inkling Small alternative runtime — checkpoint, 2026-10-19

W43.inkling-farmshare. Owner asked whether an obvious way exists to run Inkling Small. The earlier rejection
was specifically the installed vLLM/Ada custom-attention path. A ready contributor branch of llama.cpp supports
Inkling images, and Unsloth supplies a matching multimodal GGUF. This is a bounded alternative-runtime attempt,
not a claim that image inference already works on FarmShare. Existing shared environments/jobs stay unchanged.

## Submitted work — never duplicate

- **1857675**:8CPU/64GB/2h CPU build then pinned download. At checkpoint CUDA objects were compiling (13%).
- **1857671**:one node/4 L40S/16CPU/220GB/12h, afterany1857675 AND1857668 (Nemotron, last general-model job).
  This is the same GPU ID from initial submission; only failed CPU build dependencies were corrected.
- Prior CPU-only1857670/1857673/1857674 failed in CMake configuration, before model downloads or inference.
  Their logs remain. Versioned pip CUDA runtime/static paths and a missing CPU-node driver development stub
  were fixed. No GPU inference was duplicated. Do not resubmit because one old setup receipt says FAILED.

L=`/Users/cp1/Claude/Long term storage/FarmShare-inkling-20261019`
S=`/scratch/users/cp1/fs-ocr/inkling-20261019`
Read L/jobs.json and collection-status.json, then scheduler and S/logs. Final collector log collection-final.log;
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
1857675 log; a GPU skip from missing prepared.json preserves the chain. No additional setup or inference retry
is silently authorized by collection. On pass, review real image transcription/prompt/thinking behavior before
accepting scores; nonempty pilot output is a compatibility gate, not a quality judgment. Score saved895 raw
answers, failures as failures, separately from historical440 and other precision/runtime routes. Update numeric
report/ArchiveOCRBench after review; no automatic catalogue/default/adoption change. Reconcile shared TODO/DONE
and primary plan, delete this plan only when reviewed results are shipped. Manager reads trackers/Git/plan;
interactive provenance retained, no fabricated daemon engine ledger, grants or usage. No hosted money spent.
