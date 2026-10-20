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
`inkling-farmshare-20261019.md` for existing jobs1857687/1857671 and recovery; no shared vLLM patch or duplicate
NVFP4 download. GPU image compatibility is unverified until the queued pilot succeeds. Keep this item's
Ling/Nemotron jobs and collector independent.

SSH restored19Oct: preparation1857666 completed0, both Ling/Nemotron pinned roots ready; their GPU jobs remain dependency-pending. Collector restarted with archived old marker/status; current log collection-restored.log.

## Reruns — 2026-10-20 (owner-directed; supersede 1857667 and 1857668)

Both original jobs ended in TIME LIMIT (4 h) with partial caches. The collector reuses finished `<id>.json`
readings and files failed pages separately as `<id>.error.json`, and the settings contract was unchanged, so both
were resubmitted by hand with the same script and resources and only a longer limit. **Collect these job IDs, not
the old ones.**

- **Ling3 Flash VL FP8: 1860274.** 4 GPUs, 6 h. First run left 466 pages cached (421 ok, 44 cap). Rerun read the
  remaining 430 in 3 h 45 min, exit 0, no errors. `status.json`: `completed_raw`, **816 ok, 79 cap** of 895.
- **Nemotron 3.5 Super VL NVFP4: 1860275.** 2 GPUs, 7 h. First run left about 438 clean pages (369 ok, 69 cap).
  The 241 `error` files it also wrote were all produced after the server shut down at the 04:08:46 cancellation
  (`cannot schedule new futures after shutdown`): a time-limit artefact, not a model fault; the collector retries
  them automatically. Rerun was RUNNING at 14:54 on 20 Oct, 457 pages to read, expected about 4 h. Final counts
  not yet known.

Caps are terminal benchmark failures in this collector and were not rerun.

### Checking Nemotron 1860275 — for whoever picks up W43.general-sweep-farmshare (added 2026-10-20)

`W43.general-sweep-farmshare` is the queue item that closes this sweep. Do not tick it while Nemotron's job is
unfinished, and do not score a partial cache.

1. Needs the owner's open FarmShare SSH master (`~/.ssh/cm-farmshare`, Duo). Test it with
   `ssh -o ControlPath=~/.ssh/cm-farmshare -O check cp1@login.farmshare.stanford.edu`. If it is absent, do not try
   to reconnect: leave the item open and put the question to the owner in the Daemon Report.
2. Read the job: `sacct -j 1860275 -X -n -o JobID,State,Elapsed,End`. Jobs run on the cluster whatever the link
   does; read scratch with a timeout, as `tail`/`wc` there can hang.
3. **If it is still RUNNING:** leave the item open and move on. Its limit is 7 h from 13:54 on 20 Oct, so it
   ends by about 21:00 that day at the latest.
4. **If it is COMPLETED:** `nemotron35-super-vl-nvfp4/status.json` should read `completed_raw` with counts. Check
   that no `<id>.error.json` is left, then record the counts in this file and go on to review and scoring.
5. **If it is TIMEOUT or FAILED:** expect this. At 1 h 33 min it had read 80 of its 457 remaining pages, a rate
   that needs about 8 h against a 7 h limit. Finished readings are cached, so nothing is lost. Count the clean
   `<id>.json` files, record the count here, and put the question to the owner in the Daemon Report: a third
   submission with a longer limit is the likely answer, but the tracker says never to resubmit inference
   automatically, so it is the owner's call.
6. Ling3 (1860274) is already complete: 816 ok, 79 cap, no errors. Inkling is parked. Neither needs more FarmShare
   time.
