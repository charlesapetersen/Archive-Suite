#!/usr/bin/env bash
# ops/autonomous/yield-check.sh — should the Archive Suite daemon hold off for another project right now?
#
# Owner, 2026-10-04/05: Vision OCR has priority, and Archive Suite takes the spare capacity. ALL WORK RUNS AT ANY
# TIME, the owner's own use of the Mac included: there is no general rule that work waits for a free computer, and
# none should be added. The one exception is Vision OCR's MODEL BAKE-OFF, which times every page and uses up to 11 GB
# of this 18 GB Mac, so nothing heavy may run beside it (owner: "The model bakeoff is a very exceptional task").
# Archive Suite therefore waits while the bake-off job runs, and only then.
#
# The daemon calls this before each cycle's health gate and session (AUTONOMOUS_YIELD_CMD overrides the path).
# EXIT 0 and one line on stdout = yield, the line saying why. EXIT 1 = go ahead. A session already running is
# never stopped: the check only decides whether to START one.
#
# How the bake-off is recognised: its driver `bakeoff.sh` (run from a copy under $STATE/ocrlab/scripts/, or from the
# repo's ops/ocrlab/), or a read under the memory guard labelled `bakeoff.*`. Other guarded model runs (a single
# fit test, say) are ordinary work and do not make Archive Suite wait.
set -uo pipefail

pat='ocrlab/scripts/bakeoff\.sh|ops/ocrlab/bakeoff\.sh|run-guarded\.sh --label bakeoff\.'
if line="$(pgrep -fl "$pat" 2>/dev/null | head -1)" && [ -n "$line" ]; then
  label="$(printf '%s' "$line" | sed -nE 's/.*--label ([^ ]+).*/\1/p')"
  echo "Vision OCR is running its model bake-off${label:+ ($label)}"
  exit 0
fi
exit 1
