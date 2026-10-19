# General vision sweep — FarmShare checkpoint, 2026-10-19

Owner explicitly asked to check the broader W43.sweep list and queue fitting models. This follow-up is
W43.general-sweep-farmshare. It extends the prior six-model batch without changing their submitted scripts,
inputs, dependencies or outputs. Keep Codex usage low; do not wait actively for compute.

## Already submitted — never duplicate

| work | job | allocation/dependency |
|---|---:|---|
|installed-runtime audit|1857615|CPU; completed0, vLLM0.31.0/Torch2.13.0|
|pinned weight preparation|1857666|CPU8/48GB/2h; independent download/check job|
|Ling3 Flash VL FP8|1857667|one node,4 L40S/16CPU/220GB/4h; afterany1857666 AND1857612|
|Nemotron3.5 Super VL NVFP4|1857668|one node,2 L40S/8CPU/128GB/4h; afterany1857667|

The earlier single-GPU batch ends at1857612, so these additions cannot overlap it or one another. afterany
releases the next model on failure too; no automatic retries. Maximum24 additional GPU-hours. Both checkpoints
are ungated, their architectures registered in the installed runtime, and downloaded revisions are pinned in
candidates.json. This establishes eligibility; actual startup and image compatibility remain pilot gates.

L=`/Users/cp1/Claude/Long term storage/FarmShare-general-sweep-20261019`
S=`/scratch/users/cp1/fs-ocr/general-sweep-20261019`

Read L/jobs.json and collection-status.json, then scheduler and S/logs before any action. Do not infer current
completion from this note. Setup was running and both GPU jobs dependency-pending at filing. It checks pinned
HF revisions, per-candidate ceilings135GB/80GB (absolute175GB), installed model registry and available files;
per-model failures are recorded as skipped. It cannot modify the existing runtime. A missing preparation or
failed pilot ends that GPU job, preserving logs/partials and releasing its successor.

## Candidate audit

Sizes are actual safetensor bytes from primary HF metadata on19Oct, decimalGB; active parameters do not set
weight memory. Evidence JSON records exact revisions, architectures, metadata routes and installed-runtime check.
Four48GB cards is the per-user/node ceiling; leave headroom for runtime, activations and cache.

| queue candidate | measured checkpoint | disposition |
|---|---|---|
|GLM5.3 Flash|FP8 328.34GB; RedHat NVFP4 197.84GB|too large with serving headroom|
|Ling3 Flash VL|official FP8 126.19GB; INT4 76.08GB|queue FP8/4 GPUs; EP avoids block-quantization TP split issue|
|MiMo2.6 Flash/Pro|display-name repositories unavailable; released RL weights177.74/573.46GB, tagged text-generation/MiMoV2ForCausalLM|no matching downloadable vision route found; do not substitute text-only weights|
|DeepSeekV4.1 Flash|official mixed FP8/FP4 weights510.30GB|too large|
|Nemotron3.5 Super VL|BF16 248.91GB; official NVFP4 75.01GB|queue NVFP4/2 GPUs; installed mixed-precision Marlin path supports SM75+|
|MiniMaxM3|BF16 854.18GB; NVIDIA NVFP4 250.10GB|too large|
|Inkling Small|BF16 531.91GB; official NVFP4 170.73GB|raw weights within physical capacity, limited headroom; additionally hard-blocked by installed Ada attention path|

Inkling's installed nvidia/ops/fa4_rel_attention.py supplies score_mod on non-Blackwell devices. Its FA4 cute
interface.py explicitly raises NotImplementedError for that custom operation when arch//10==8 (L40S is SM89).
Exact source hashes/excerpts are in evidence and L/inkling-blocker.txt. A registry entry alone is insufficient.
Do not download170GB or submit a doomed Inkling job until a tested Ada backend exists. This is a concrete
runtime blocker, not a claim that no alternative software could ever run it. No runtime rebuild is in scope.
MiMo's available 9B vision-capable distill is agent/coding SFT rather than the named Flash/Pro checkpoint;
W43.sweep says drop coding variants, so it was not silently substituted. Hosted vision models remain deferred.

Primary cards: [Ling](https://huggingface.co/inclusionAI/Ling-3.0-flash-VL-fp8),
[Nemotron](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Super-VL-120B-A12B-NVFP4),
[Inkling](https://huggingface.co/thinkingmachines/Inkling-Small-NVFP4),
[GLM NVFP4](https://huggingface.co/RedHatAI/GLM-5.3-Flash-NVFP4),
[MiniMax NVFP4](https://huggingface.co/nvidia/MiniMax-M3-NVFP4),
[DeepSeek](https://huggingface.co/deepseek-ai/DeepSeek-V4.1-Flash),
[MiMo released models](https://huggingface.co/XiaomiMiMo/models).

## Protocol, collection and daemon finish

Each isolated model root has prepared.json, fixed panel prompt, frozen legacy collector, cache-contract.json,
status.json, pilot-summary.json, raw per-page files and server logs. Reuse the same L1/L4/L8 three-page pilot,
895 existing checksum-verified JPEGs,8192 output tokens, temperature0 and thinking-off request as the prior batch.
No new corpus/images or truth editing. All three must answer nonempty, uncapped stop before full. Full reuses
those three pilot answers (895 calls/model total), preserves terminal caps and never retries on its own.
Raw completion requires895 matching page/model/image identities. Review semantic/protocol validity separately.

New multi-GPU wrapper reads literal argument arrays, no eval: TP4+EP for Ling, TP2 for Nemotron, context16384,
BF16 KV, util.90,4 sequences/requests, eager execution and ordinary NCCL all-reduce. Nemotron uses float16 Mamba
state. Official remote model code may load from the pinned snapshot; HF offline during inference. Raw cache
binds revision/prompt/decoding/vLLM/server args independently of manifest size. Existing six jobs retain their
frozen script copies; changing tracked helper defaults does not alter them.

L/recovery/open_sweep_collect.py runs under48h caffeinate, polls180s, retrieves each terminal model (including
failed partial outputs) to L/outputs/<key>, then logs to L/remote-logs and exits. No LLM tokens, submission,
inference retry, auth retry or daemon start. Check its existing marker/PID/status before restarting retrieval.
It stops on SSH loss without affecting submitted Slurm work. Keep the owner's cm-farmshare master/socket open.
All running script references are durable outside temporary Git worktrees.

When jobs finish: inspect prepared/status/server/pilot outputs, score saved answers only (failures stay failures),
label precision and per-stratum895 results, preserve the historical440 comparison and native specialist routes.
Publish numeric report/ArchiveOCRBench updates after review; no automatic app default/adoption decision.
If timed out, retain per-page cache and checkpoint; do not silently repeat inference. Move the whole queue item
to DONE, tick primary plan and delete this plan only after results review is complete. Agent Manager reads the
shared trackers/plan/Git; no fabricated daemon session, grant, PID or usage ledger. No paid calls or daemon start.


## Inkling alternative follow-up — owner19Oct

The blocker above is specific to installed vLLM, not every runtime. W43.inkling-farmshare now queues an
isolated pinned llama.cpp contributor branch with Unsloth Q4 GGUF and its vision projector. See
`inkling-farmshare-20261019.md` for existing jobs1857675/1857671 and recovery; no shared vLLM patch or duplicate
NVFP4 download. GPU image compatibility is unverified until the queued pilot succeeds. Keep this item's
Ling/Nemotron jobs and collector independent.
