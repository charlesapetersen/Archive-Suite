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

- No engine session submits, inspects or collects Sherlock work. Every open cluster item carries
  `(cluster: sherlock) (needs: owner)`, which the queue hook holds for the owner.
- Sherlock work runs in a session the owner starts. A bounded session may finish its task while the owner is away:
  waiting for a job, fixing what failed and resubmitting, then stopping.
- The owner's shared login is `ssh -o ControlMaster=yes -o ControlPath=~/.ssh/cm-sherlock -o ControlPersist=8h
  cp1@login.sherlock.stanford.edu` (Duo). Nothing keeps it alive unattended: no keepalive loop like FarmShare's.

## Data already on Sherlock

FarmShare's `/scratch/users/cp1/fs-ocr/` as of 2026-10-22 (packs, adapters, checkpoints, results; not the HF weights,
venvs or merged models) is in `$GROUP_HOME/cp1/archive-suite/FarmShare-scratch-20261022/fs-ocr/`, topped up after
the 10:48 cancellations, with `farmshare-home/` holding `cancelled-20261022.txt` and `fs-enclosurepack/`. Stage a
pack from there into `$SCRATCH` inside a job; do not copy it from FarmShare again.

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

## Capacity

Public `gpu` partition on 2026-10-22 morning: 200 GPUs, 14 idle, 1,216 GPU requests queued; cards include L40S
(48 GB) and H100 SXM5 (80 GB). Wall limit 2 days. The first probe job and its figures are recorded below once it
runs.
