# Additional open-model FarmShare sweep — checkpoint, 2026-10-19

Owner19Oct: expand the open-weight part of W43.sweep using ready/nearly-ready pipelines. Minimize Codex
usage, run models sequentially and pause before exhaustion. This is W43.open-sweep-more, a separate free
follow-up; W43.sweep's paid/pre-release gates remain. No corpus expansion or runtime/package upgrade.

## Jobs already submitted — collect these, never duplicate

Preparation1857614 **COMPLETED0**: all six models downloaded/pinned and their architectures recognized by
installed vLLM. The first CPU attempt1857606 caught a ModelCardData conversion bug before downloads/inference;
its receipts are preserved, reader corrected and only CPU preparation repeated. Six GPU IDs were retained.

| order | job | candidate | route |
|---|---:|---|---|
|1|1857607|zai-org/GLM-OCR|native `Text Recognition:`|
|2|1857608|Qwen/Qwen3-VL-8B-Instruct|original panel prompt|
|3|1857609|lightonai/LightOnOCR-3-0.8B|native image only|
|4|1857610|lightonai/LightOnOCR-3-4B|native image only|
|5|1857611|PaddlePaddle/PaddleOCR-VL-1.5|native `OCR:`|
|6|1857612|Qwen/Qwen3.5-4B|original panel prompt|

At checkpoint all six wait on dependencies. First waits afterany1857614 AND1857599/1857600/1857601 (the
previous OCR extension); each subsequent job waits afterany its predecessor. A failed/skipped model releases
the next. Only one of these six consumes a GPU at a time. Each has1 L40S/8CPU/64GB/4h; maximum24 GPU-hours,
no hosted invoice. CPU preparation was8CPU/48GB/2h,25GB weights/model ceiling, excludes gated/private models.
Read `verification/evidence/segbench/open-sweep-20261019.json` for exact model SHAs, paths, source hashes,
licenses, byte counts, manifest checksum and recorded dependency arguments. Do not infer live state from prose.

L=`/Users/cp1/Claude/Long term storage/FarmShare-open-sweep-20261019`
S=`/scratch/users/cp1/fs-ocr/open-sweep-20261019`
R=`/scratch/users/cp1/fs-ocr/interactive-20261018`

## Protocol and pilot gate

Each model has an isolated S/<key> with pinned `prepared.json`, `ocr/panel-prompt.txt`, frozen collector,
`cache-contract.json`, server logs and `results/ocr/<key>/<page-id>.json`. Server uses its pinned local snapshot
with HF offline; raw answer records identify the original model repository. Installed vLLM/environment unchanged.
Original server settings: TP1/context16384/BF16 KV/util.90/16 sequences; collector2400px JPEG90,8192 output-token
cap, temperature0, thinking disabled, concurrency8. Native prompts differ deliberately; label those routes
separately from controlled panel rows. Sources: each model's linked HF card in preparation-receipt evidence;
[LightOn instructions](https://huggingface.co/lightonai/LightOnOCR-3-4B) and
[Paddle instructions](https://huggingface.co/PaddlePaddle/PaddleOCR-VL-1.5) define the native input choices.

Pilot uses three existing pages (L1/L4/L8): btp__mss11049004-95, si__NMAAHC-007630087_00342,
ocrd__aepinus_bekentnis_1548_aepinus_bekentnis_1548_0007. All must return nonempty uncapped stop answers.
Transport error, cap, blank or startup failure stops that model; no automatic retry. This checks compatibility,
not semantic accuracy. A pass reads the895 frozen public pages, reusing all three pilot answers (895 calls total,
never898). All images are checksum-checked original packs; no new source construction or image re-encoding.
Per-page outputs persist on timeout/failure. Full-run caps remain terminal scored failures, never silently retried.

`status.json` states pilot/full/completed_raw/needs_inspection; `pilot-summary.json` preserves pilot counts.
`completed_raw` requires895 matching page IDs/image hashes/model identities. Cache contract excludes manifest
size so future additions can reuse unchanged readings with matching settings; changed inputs/settings belong
in a separate experiment. Do not merge any cache with the prior Qwen27B/35B runs or their440-page comparisons.

## Collection and next daemon session

L/jobs.json is the durable receipt. A non-LLM collector runs under a48h caffeinate assertion, polls180s through
the existing cm-farmshare master, retrieves each terminal model (including failed partial outputs), then exits.
It never submits, reauthenticates, retries inference, calls hosted models or consumes Codex usage. L/collection-status.json
and L/collection.log show its state. L/outputs/<key> contains each retrieved model root; L/remote-logs holds Slurm
logs when all end. It stops on SSH failure, leaving the submitted jobs running remotely. Do not close the owner's
master/socket/shell. A local collector ending never means a remote job was cancelled.

Read collection status first, then scheduler and S/<key>/{prepared,status}.json/logs. If collector already exists,
let it finish. If it stopped, inspect its marker/PID/status before explicitly restarting retrieval; never rerun
setup or sbatch based on a missing local file. Source is corpus/open_sweep_collect.py; recovery copy at L/recovery.
All executable copies used remotely/local collector live outside the temporary Git worktree. Syntax/compile
checks pass; actual GPU pilots are intentionally queued rather than waited on with Codex active.

Next: inspect pilot raw outputs and native formatting; score saved outputs only, preserving caps/missing pages
as failures and reporting per-stratum895 results separately from historical440 references. Use the unchanged
source/truth manifests in FarmShare-20261019/recovery. Add numeric/report/ArchiveOCRBench outputs only after
protocol review; no catalogue/default/adoption change based merely on pilot completion. Pin raw provenance.
When reviewed, move W43.open-sweep-more into DONE, tick the primary plan and delete this execution plan.

Remaining sweep candidates (olmOCR-2, dots.ocr, Surya and larger/hosted models) remain under W43.sweep. Their
custom prompts/rendering/layout-output handling or size need more preparation; no opportunistic environment
rebuild while subscription usage is low. Qwen3.8 FlashNext remains excluded by prior memory/weight-size audit.
This checkpoint only expands free ready pipelines. Prior OCR/public-segmentation follow-ups remain independent.

Agent Manager sees this through shared SUITE_TODO, the mirrored locked primary plan, pushed Git checkpoint
and Session Log. Interactive provenance is preserved; no fake daemon session ledger, grant, PID or usage record.
