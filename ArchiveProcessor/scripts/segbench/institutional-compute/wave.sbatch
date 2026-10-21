#!/usr/bin/env bash
# W46.cluster-waves — a wave job's last link: a CPU job after the full run (afterany), submitted by wave.py submit.
# wave.py score waits out requeued bulk shards (exit 75: this job submits itself again after them), runs the job's
# score command and leaves the small result files in <IC_ROOT>/waves/<wave>/results/<id>/. Do not sbatch it by hand.
# Env from wave.py: IC_DIR IC_WAVE_DIR IC_PY IC_ROOT and the profile's IC_CPU_* / IC_ACCOUNT / IC_MAXWALL_MIN.
set -euo pipefail
cd "$IC_DIR"
: "${IC_WAVE_DIR:?wave.py must export the job folder}" "${IC_PY:?wave.py must export the runtime}"
set +e
"$IC_PY" wave.py score "$IC_WAVE_DIR"
rc=$?
set -e
if [ $rc -eq 75 ]; then
  # Any failure to queue the next round is reported, never silent: requeued shards would run with nobody watching.
  if args_text="$("$IC_PY" wave.py score-args "$IC_WAVE_DIR")"; then
    args=(); while IFS= read -r line; do args+=("$line"); done <<<"$args_text"
    if IC_SCORE_ROUND=$(( ${IC_SCORE_ROUND:-0} + 1 )) sbatch --parsable --export=ALL "${args[@]}" \
        "--dependency=afterany:$(cat "$IC_WAVE_DIR/score-wait")" wave.sbatch; then
      exit 0
    fi
  fi
  "$IC_PY" wave.py report "$IC_WAVE_DIR" failed "the score job could not queue itself after shard job(s) $(cat "$IC_WAVE_DIR/score-wait")"
  exit 1
fi
exit $rc
