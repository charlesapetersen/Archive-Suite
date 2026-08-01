#!/usr/bin/env bash
# prove-status.sh — prove status-digest.sh reports the RIGHT state for every situation the owner can walk
# into, and never the confidently-wrong one. Runs the REAL renderer against throwaway state dirs, with a
# stubbed `pgrep`/`launchctl`/`security` so each branch is reachable without a daemon. $0, no network, no
# writes outside $TMPDIR.
#
# WHY THIS EXISTS. The status line is the one thing the owner reads to decide whether to intervene, and it
# has now lied twice: `tart` off PATH was reported as a missing VM, and an hour of 429s was reported as
# "sessions finding no actionable work" (SUITE_TODO W21.vmgui-path, W23.status1). Both were single lines
# with no test behind them. The states below are exactly the ones that must never be confused for each
# other, because each implies a DIFFERENT owner action:
#     working · throttled (wait) · idle-no-work (unblock it) · parked (decide) · crash-looping (restart)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; DIGEST="$HERE/../status-digest.sh"
[ -f "$DIGEST" ] || { echo "no digest at $DIGEST"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo with space"; mkdir -p "$R"        # space: mirrors the real repo path
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); printf '        ---- output ----\n%s\n        ----------------\n' "${2:-}"; }

# ---- stub PATH: pgrep/launchctl/security are the three things that decide the state ------------------
BIN="$T/bin"; mkdir -p "$BIN"
mkstub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
# RUNNING / SUPERVISED / TASKPORT are read at CALL time from the environment, so each case can flip them.
mkstub pgrep    'case "${RUNNING:-0}" in 1) echo 4242; exit 0;; *) exit 1;; esac'
mkstub launchctl 'case "${SUPERVISED:-0}" in 1) echo "last exit code = ${LASTEXIT:-0}"; exit 0;; *) exit 1;; esac'
mkstub security  'case "${TASKPORT:-0}" in 1) echo "<string>allow</string>";; esac; exit 0'
# df/date/git/awk etc. still come from the real PATH, appended after the stubs.
run() { PATH="$BIN:$PATH" AUTONOMOUS_REPO="$R" AUTONOMOUS_STATE="$S" AUTONOMOUS_PLAN="$P" bash "$DIGEST" "$@" 2>&1; }

# ---- a throwaway repo + plan + state dir -------------------------------------------------------------
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf -- '- [ ] one\n- [ ] two\n- [x] three\n' > "$R/SUITE_TODO.md"
git -C "$R" add -A; git -C "$R" commit -qm "seed: the first change"
P="$R/plan.md"; S="$T/state"; mkdir -p "$S"
write_plan() { printf 'RUN STATUS: IN_PROGRESS — test\n\n## HOLD QUEUE\n%s\n\n## Morning Review\n%s\n\n## Next\n' "${1:-}" "${2:-}" > "$P"; }
write_plan "" ""
: > "$S/daemon.log"

echo "[0] the finished count includes the SUITE_TODO_DONE archive"
# Regression 2026-08-01: completed items were split out of SUITE_TODO into SUITE_TODO_DONE.md (finishing an
# item MOVES its entry rather than ticking it in place). The digest still counted only SUITE_TODO, so the
# live status collapsed from "162 finished" to "1 finished". This suite PASSED throughout — its fixture had
# a [x] sitting in SUITE_TODO, which is precisely the shape the new convention stops producing.
printf -- '- [x] archived-one\n- [x] archived-two\n' > "$R/SUITE_TODO_DONE.md"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -qE '2 tasks to do · 3 finished' \
  && ok "finished = SUITE_TODO [x] + SUITE_TODO_DONE [x]" || bad "archive not counted" "$OUT"
rm -f "$R/SUITE_TODO_DONE.md"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -qE '2 tasks to do · 1 finished' \
  && ok "a missing archive is a no-op (works pre-split too)" || bad "missing archive broke the count" "$OUT"

echo "[1] not running -> says so, and says how to start it"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -q 'Not running' && printf '%s' "$OUT" | grep -q 'arm.sh' \
  && ok "stopped state names the fix" || bad "stopped state wrong" "$OUT"

echo "[2] running with no idle marker -> Working now"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Working now' && ok "working state" || bad "working state wrong" "$OUT"
# ...and it must say HOW LONG on the current task, or a wedged session reads exactly like a healthy one.
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M')" "$S/engine.lock"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'into its current task' && ok "reports time on the current task" || bad "no task age" "$OUT"
printf '%s' "$OUT" | grep -qE '2 hours into' && ok "the age is right (2 hours)" || bad "wrong age" "$OUT"
rm -f "$S/engine.lock"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Working now' && ok "degrades to plain 'Working now' with no lock file" || bad "broke without engine.lock" "$OUT"

echo "[3] running + idle + a 429 in the last session -> THROTTLED, and explicitly not 'out of work'"
echo "$(( $(date +%s) - 3000 ))" > "$S/idle.since"
printf '{"is_error":true,"api_error_status":429}\n{"resetsAt":%s}\n' "$(( $(date +%s) + 900 ))" > "$S/last-session.log"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -qi 'Paused' && printf '%s' "$OUT" | grep -q 'usage cap' \
  && ok "throttle reported as a cap" || bad "throttle not reported" "$OUT"
printf '%s' "$OUT" | grep -qi 'NOT out of work' \
  && ok "explicitly denies the empty-queue reading (the W23.status1 bug)" || bad "missing the denial" "$OUT"
printf '%s' "$OUT" | grep -qi 'not finding anything' \
  && bad "STILL claims no actionable work while throttled" "$OUT" || ok "does not claim 'nothing to do'"

echo "[4] running + idle + NO rate limit -> genuinely out of work (the other reading, still available)"
rm -f "$S/last-session.log"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -qi 'not finding anything' && ok "idle-no-work state" || bad "idle-no-work wrong" "$OUT"
printf '%s' "$OUT" | grep -qi 'Paused' && bad "claims throttled with no 429 present" "$OUT" || ok "does not invent a cap"
rm -f "$S/idle.since"

echo "[5] STATUS_PARKED wins over a live process (the daemon sets it mid-park)"
OUT="$(RUNNING=1 STATUS_PARKED='everything is blocked' run)"
printf '%s' "$OUT" | grep -q 'Stopped itself' && ok "park flag beats pgrep" || bad "park flag ignored" "$OUT"

echo "[6] PARKED in the log, process gone -> parked, not merely 'stopped'"
echo "2026-01-01 00:00:00  PARKED (blocked)" >> "$S/daemon.log"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -q 'Stopped itself' && ok "log-detected park" || bad "log-detected park missed" "$OUT"
: > "$S/daemon.log"

echo "[7] supervised but no process -> crash-loop warning, NOT a calm 'not running'"
OUT="$(RUNNING=0 SUPERVISED=1 LASTEXIT=1 run)"
printf '%s' "$OUT" | grep -q 'not running right now' && ok "crash-loop surfaced" || bad "crash-loop hidden" "$OUT"
printf '%s' "$OUT" | grep -q 'Not running$' && bad "reads as a clean stop" "$OUT" || ok "distinguished from a clean stop"

echo "[8] 'Needs you' stays empty when nothing is wrong, and fills when things are"
touch "$S/keychain-partition-fixed"            # otherwise the keychain ask is (correctly) always present
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Nothing right now' && ok "quiet when there is nothing to ask" || bad "invented an ask" "$OUT"
write_plan "- [ ] held thing" "- [ ] decide this thing"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'held back for you' && ok "hold queue surfaced" || bad "hold queue missed" "$OUT"
printf '%s' "$OUT" | grep -q 'waiting on your decision' && ok "morning-review count surfaced" || bad "morning review missed" "$OUT"
OUT="$(RUNNING=1 TASKPORT=1 run)"
printf '%s' "$OUT" | grep -q 'security setting is still relaxed' && ok "taskport surfaced" || bad "taskport missed" "$OUT"
write_plan "" ""

echo "[9] a '## ' heading inside Morning Review ends the scan (documented trap — must not silently empty)"
printf 'RUN STATUS: x\n\n## Morning Review\n## Oops\n- [ ] hidden\n' > "$P"
OUT="$(RUNNING=1 run)"
# Deterministic, so assert it rather than accepting either outcome: the awk ends the section at the first
# `## `, so the item below it is invisible here. That is by design (it bounds the section) but it is also a
# real trap — the plan file carries a comment forbidding a `## ` sub-heading there for exactly this reason.
printf '%s' "$OUT" | grep -q 'Nothing right now' \
  && ok "a '## ' sub-heading ends the scan — items under it are NOT counted (documented trap)" \
  || bad "scan ran past a '## ' heading; the section is no longer bounded" "$OUT"
write_plan "" ""

echo "[10] the default view stays SHORT and jargon-free; --details is where the rest lives"
OUT="$(RUNNING=1 run)"
n="$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
[ "$n" -le 16 ] && ok "default view is $n lines (<=16)" || bad "default view bloated to $n lines" "$OUT"
for word in WS5 digest backlog SUITE_TODO hold-queue cadence keychain launchd; do
  printf '%s' "$OUT" | grep -qi -- "$word" && bad "jargon '$word' leaked into the default view" "$OUT" || ok "no '$word' in default view"
done
OUT="$(RUNNING=1 run --details)"
printf '%s' "$OUT" | grep -qi 'keychain' && ok "--details has the keychain line" || bad "--details missing keychain" "$OUT"
printf '%s' "$OUT" | grep -qi 'disk free' && ok "--details has disk" || bad "--details missing disk" "$OUT"
printf '%s' "$OUT" | grep -qi 'GUI checks' && ok "--details has the GUI lane" || bad "--details missing GUI" "$OUT"

echo "[11] no colour escapes when the output is a FILE (the daemon writes STATUS.md)"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q $'\033' && bad "ANSI escapes in non-tty output" "$OUT" || ok "clean text when piped"

echo "[12] degrades instead of erroring when every source is missing"
OUT="$(RUNNING=0 AUTONOMOUS_PLAN="$T/nope.md" bash -c 'PATH="'"$BIN"':$PATH" AUTONOMOUS_REPO="'"$T"'/nothing" AUTONOMOUS_STATE="'"$T"'/nostate" AUTONOMOUS_PLAN="'"$T"'/nope.md" bash "'"$DIGEST"'"' 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exits 0 with no repo/plan/state" || bad "errored on missing sources (rc=$rc)" "$OUT"
printf '%s' "$OUT" | grep -q 'Archive Suite' && ok "still prints a report" || bad "printed nothing useful" "$OUT"

echo
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
