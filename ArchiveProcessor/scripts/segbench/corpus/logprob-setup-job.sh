#!/bin/bash
# W46.ocr-logprob: the CPU download job (logprob_setup.py), as open-sweep-20261019/setup-job.sh runs open_sweep_setup.py.
#   sbatch ... logprob-setup-job.sh ROOT
set -euo pipefail
ROOT="$1"
source /home/users/cp1/Archive-Suite/ArchiveProcessor/scripts/segbench/farmshare/fs.env
export HF_HOME HF_HUB_DOWNLOAD_TIMEOUT=90 TOKENIZERS_PARALLELISM=false
unset HF_HUB_OFFLINE
exec "$FS_PY" "$ROOT/logprob_setup.py" "$ROOT"
