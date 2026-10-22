#!/bin/bash
# W46.ocr-loops: several route x arm pairs in turn inside one GPU job (the gpu QOS takes 32 submitted jobs per user).
#   sbatch ... loop-rerun-seq.sh ROOT ROUTE:ARM [ROUTE:ARM ...]
# Each pair is its own loop-rerun-job.sh process, so each stops its server on exit before the next starts. A failed
# pair is reported and the rest go on; the job fails if any pair did.
set -uo pipefail
ROOT="$1"; shift
failed=0
for pair in "$@"; do
  echo "== $pair $(date +%T)"
  bash "$ROOT/loop-rerun-job.sh" "$ROOT" "${pair%%:*}" "${pair#*:}" || { echo "== $pair FAILED"; failed=1; }
done
exit "$failed"
