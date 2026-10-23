# Sherlock access

Owner, 2026-10-22: the Sherlock account (group `pedror`) is approved, and the corpus and the public sets are Low or
Moderate Risk data, which Sherlock accepts. Cluster work runs on Sherlock from now on, in sessions the owner starts;
FarmShare only with his explicit approval for that run. The rule is in CLAUDE.md beside the gateway rules.

Sherlock's rules for automated tools are installed on every node as `/etc/agents/AGENTS.md`, with topic files
beside it (`policy.md`, `slurm.md`, `storage.md`, `software.md`). They apply to any tool that drives Sherlock over
SSH, not only to tools running there. Read `AGENTS.md` again at the start of every session that touches Sherlock
(its rule 12): this page is a summary for planning, not a substitute.

## The engine may not drive Sherlock

`policy.md` forbids "supervisors, watchdogs, cron-like loops or scripts that keep agent sessions alive, restart
them or feed them new prompts when nobody is there", and sessions picked up day after day without a person in the
loop. The Agent Manager engine is that kind of supervisor. So:

- No engine session submits, inspects or collects Sherlock work, or opens any connection to Sherlock. The engine
  prepares a `(cluster: sherlock)` item on the Mac and ends with `plan-edit.sh hold`, which adds `(needs: owner)`;
  the queue hook offers Sherlock items without a preflight (`cluster-reach.py` `PREP_ONLY`). Root CLAUDE.md has the
  hand-over in full.
- Sherlock work runs in a session the owner starts. A bounded session may finish its task while the owner is away:
  waiting for a job, fixing what failed and resubmitting, then stopping.
- The owner's shared login is `ssh -o ControlMaster=yes -o ControlPath=~/.ssh/cm-sherlock -o ControlPersist=8h
  cp1@login.sherlock.stanford.edu` (Duo). Nothing keeps it alive unattended: no keepalive loop like FarmShare's.

## Before a submission

Every Sherlock job is reviewed for size and necessity first (root CLAUDE.md, "Every Sherlock job is reviewed"): the
question and what it would change, why current results do not settle it, job count and pilot GPU-hours, why nothing
smaller would do, and useful-now or nice-to-have. The owner's session reads the review in the item's notes before
it submits, and sends a nice-to-have item behind `W46.nice-to-have` instead.

## Data already on Sherlock

FarmShare's `/scratch/users/cp1/fs-ocr/` as of 2026-10-22 (packs, adapters, checkpoints, results; not the HF weights,
venvs or merged models) is in `$GROUP_HOME/cp1/archive-suite/FarmShare-scratch-20261022/fs-ocr/`, topped up after
the 10:48 cancellations, with `farmshare-home/` holding `cancelled-20261022.txt` and `fs-enclosurepack/`. Stage a
pack from there into `$SCRATCH` inside a job; do not copy it from FarmShare again.

The copy has gaps a pack's paths can fall into (2026-10-23, 23 jobs failed on these overnight):
- FarmShare's `$HOME/fs-truthpack` (the owner's 99 truth pages, named by the regions, logprob, postcorrect and every
  96-set run) was never copied. It is now in Sherlock's `$HOME/fs-truthpack`, the same absolute path, rebuilt on the
  Mac with `institutional-compute/cluster_ocr.py pack`; its 99 images match every hash the packs record.
- Some images a pack names under `interactive-20261019/ocr/images` sit only in the `interactive-20261018` folder.
- FarmShare's venvs carried packages the vLLM image does not (scipy); `$SH_ENH_EXTRA` holds them for the
  enhancement arms.
Before a submission, check every path the pack's json, jsonl, tsv and sh files name, home paths included, not only
`/scratch` ones. `sherlock/resubmit-20261023.sh` checks its own inputs before it queues anything.

Results come home to `$GROUP_HOME/cp1/archive-suite/sherlock-results/` (`fix-20261023-job.sh` copies them, without
models, page images, weights or clones) and to the Mac in `~/Library/Caches/ArchiveSuiteRehearsal/sherlock-results/`.

## Rules a Sherlock job or session follows

- Login nodes are for editing, inspection and submitting jobs. Installs, compiles, model downloads and copies
  inside Sherlock run in a job (`sbatch`, or `sh_dev` for an interactive one). Nothing server-like on a login node.
- Every job states `--time`. GPU jobs use `-p gpu -G <n>` and select cards with `-C` features from `sh_node_feat`
  (for example `GPU_MEM:48GB|GPU_MEM:80GB`), never `--exclude`. There is no `--account`. The kit's
  `--gres=gpu:N` and its FarmShare QOS do not carry over; a Sherlock profile has to change `scheduler.sh`.
- Storage: environments in `$GROUP_HOME` (1 TB), never in `$SCRATCH`. Job input and output in `$SCRATCH`
  (100 TB, purged 90 days after last modification, not backed up). Caches (`PIP_CACHE_DIR`, `XDG_CACHE_HOME`,
  `HF_HOME`) in `$SCRATCH`. Results are copied home promptly; scratch never holds the only copy.
  Never touch files to keep them from being purged: the penalty is the account.
- Prefer fewer, larger files; keep heavy I/O off `$HOME` and `$GROUP_HOME`.
- Check the scheduler no more than once a minute. Chain stages with `--dependency`, never a polling loop. Never
  submit a duplicate because a job is pending; never resubmit a failure without its cause. Work inside a job lasts
  at least 10 minutes.
- No SSH server of any kind on any node; no unattended tunnels; no `scrontab` or self-resubmitting agent jobs.
- If something on the system looks broken, stop and tell the owner with a short draft for
  srcc-support@stanford.edu. Never contact SRCC or anyone else ourselves.

## Capacity and the software route

Public `gpu` partition on 2026-10-22: 200 GPUs (L40S 48 GB and H100 SXM5 80 GB among them), 14 idle in the morning
with 1,216 GPU requests queued; wall limit 2 days; the `gpu` QOS allows 16 GPUs, 128 CPUs and 100 submitted jobs
per user. Four one-GPU probe jobs that day waited 76 s, 7.5 min, 15 min and 7 min.

Sherlock runs CentOS 7 (glibc 2.17) with NVIDIA driver 550, so the pip wheels of vLLM 0.31 / torch 2.13 that
FarmShare used do not install (49017776). vLLM's own image `vllm/vllm-openai:v0.31.0-x86_64-cu129` does run: built
as a SIF on the CPU partition (about an hour, 12 GB, `$GROUP_HOME/cp1/images/`; on a GPU node with temp on
`$L_SCRATCH_JOB` mksquashfs died with 139), torch 2.13 cu129 sees the card on driver 550, and Qwen3-VL 8B served on
an L40S read 30 of the owner's truth pages in 102 s (about 1,050 pages an hour, 2 capped; job 49048708). One fix is
needed: the image's torchcodec 0.17 is a CUDA 13 build with no FFmpeg, so a `sitecustomize.py` on PYTHONPATH marks it
absent (`ArchiveProcessor/scripts/segbench/sherlock/`, which holds the env file, the container wrappers, the stage
job and the 2026-10-22 restart).
