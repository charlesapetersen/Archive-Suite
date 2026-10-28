#!/bin/bash
# The batch's two CPU jobs (W46.sherlock-batch), submitted by batch.py, never by hand:
#   sbatch ... batch-job.sh SH_DIR imports BATCH   (SH_DIR: a job runs from Slurm's spool copy, so it is passed in)
#   imports BATCH   import each submitted pack's chain in the vLLM image, then release or cancel its held jobs
#   copy BATCH      copy each finished pack's job evidence into its results folder (collected.tsv)
set -euo pipefail
SH_DIR="$1"; shift
source "$SH_DIR/sh.env"
exec python3 "$SH_DIR/batch.py" "$@"
