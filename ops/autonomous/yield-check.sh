#!/usr/bin/env bash
# ops/autonomous/yield-check.sh — should the Archive Suite daemon hold off for another project right now?
#
# Owner, 2026-10-04: Vision OCR has priority, and Archive Suite takes the spare capacity. This Mac has 18 GB.
# A Vision OCR model job (the OCR bake-off and its kin) uses up to 11 GB, times every page, and runs under a
# memory guard that kills and retries a read when memory runs short. An Archive Suite session builds three
# apps and boots a test VM, which needs several GB more. Asked when Archive Suite may run, the owner chose
# "Not during model jobs": Archive Suite waits while a Vision OCR model job runs, and otherwise runs beside
# Vision OCR's own sessions, whose suite is slower for it.
#
# The daemon calls this before each cycle's health gate and session (AUTONOMOUS_YIELD_CMD overrides the path).
# EXIT 0 and one line on stdout = yield, the line saying why. EXIT 1 = go ahead. A session already running is
# never stopped: the check only decides whether to START one.
#
# How a model job is recognised: every Vision OCR model run goes through its memory guard, `run-guarded.sh`,
# and the bake-off's driver is `bakeoff.sh` (both run from copies under $STATE/ocrlab/scripts/ or from the
# repo's ops/ocrlab/). A process matching either is a model job.
set -uo pipefail

pat='ocrlab/scripts/(run-guarded|bakeoff)\.sh|ops/ocrlab/(run-guarded|bakeoff)\.sh'
if line="$(pgrep -fl "$pat" 2>/dev/null | head -1)" && [ -n "$line" ]; then
  label="$(printf '%s' "$line" | sed -nE 's/.*--label ([^ ]+).*/\1/p')"
  echo "Vision OCR is running a model job${label:+ ($label)}"
  exit 0
fi
exit 1
