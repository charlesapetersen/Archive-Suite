#!/bin/bash
# The old FarmShare kit's job.sbatch for a text pack, run from its staged copy ($FS_ROOT/text-kit, stage-job.sh).
# sbatch reads a script at submission, so this wrapper lets restart-20261022.sh submit before the kit is staged.
set -euo pipefail
exec bash "$FS_DIR/job.sbatch"
