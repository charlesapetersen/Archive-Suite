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
# ⚠ ISOLATE $HOME. status-digest.sh reads "$HOME/Desktop/ARCHIVE-SUITE-RUN-PARKED.txt" to decide whether to
# print a "it parked and left you a note" ask, so without this the OWNER'S REAL DESKTOP leaks into the
# assertions. Measured 2026-08-06: with a real park note present this harness reported 34 passed / 2 FAILED
# ("invented an ask" and "scan ran past a '## ' heading"), and 36/0 with no note — i.e. the two failures were
# an environment leak, not a defect, and the harness's verdict depended on a file outside the sandbox.
# prove-daemon.sh already did this (its header promises to "never touch the owner's Desktop"); this did not.
export HOME="$T/home"; mkdir -p "$HOME/Desktop"
R="$T/repo with space"; mkdir -p "$R"        # space: mirrors the real repo path
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); printf '        ---- output ----\n%s\n        ----------------\n' "${2:-}"; }

# ---- stub PATH: pgrep/launchctl/security are the three things that decide the state ------------------
BIN="$T/bin"; mkdir -p "$BIN"
mkstub() { printf '#!/bin/sh\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
# RUNNING / SUPERVISED / TASKPORT are read at CALL time from the environment, so each case can flip them.
mkstub pgrep    'case "$*" in
  *archive-suite-autonomous.sh*) [ "${RUNNING:-0}" = 1 ] && { echo 4242; exit 0; } ;;
  *"autonomous maintenance session for the Archive Suite"*) [ "${SESSION:-0}" = 1 ] && { echo 4343; exit 0; } ;;
  *health-gate*) [ "${HEALTH_GATE:-0}" = 1 ] && { echo 4444; exit 0; } ;;
esac
exit 1'
mkstub launchctl 'case "${SUPERVISED:-0}" in 1) echo "last exit code = ${LASTEXIT:-0}"; exit 0;; *) exit 1;; esac'
mkstub security  'case "${TASKPORT:-0}" in 1) echo "<string>allow</string>";; esac; exit 0'
# df/date/git/awk etc. still come from the real PATH, appended after the stubs.
run() { PATH="$BIN:$PATH" AUTONOMOUS_REPO="$R" AUTONOMOUS_STATE="$S" AUTONOMOUS_PLAN="$P" SESSION="${SESSION:-0}" bash "$DIGEST" "$@" 2>&1; }

# ---- a throwaway repo + plan + state dir -------------------------------------------------------------
git -C "$R" init -q; git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf -- '- [ ] one\n- [ ] two\n- [x] three\n' > "$R/SUITE_TODO.md"
git -C "$R" add -A; git -C "$R" commit -qm "seed: the first change"
P="$R/plan.md"; S="$T/state"; mkdir -p "$S"
write_plan() { printf 'RUN STATUS: IN_PROGRESS — test\n\n## WORK QUEUE\n%s\n\n## HOLD QUEUE\n%s\n\n## Daemon Report\n%s\n\n## Next\n' "${3:-}" "${1:-}" "${2:-}" > "$P"; }
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

echo "[0b] W26.donecount — a WRAPPED PROSE line that merely starts with **bold** is NOT a checkbox item"
# The counters used `^\s*[-*].*\[ \]`, where `[-*]` accepts the `*` of `**bold**` and `.*` then reaches a
# checkbox anywhere later in the line. So an ordinary continuation line inside an entry — "**Then guard it.**
# In SUITE_TODO.md a column-0 `- [x]` is always the stub bug" — counted as a finished ITEM. This is not
# hypothetical: writing the W26.donecount entry tripped it three times (+2, +1, +1), each caught only by
# re-measuring before commit. Both counters now anchor the checkbox to the bullet with `[[:space:]]+`.
# The two prose lines below are verbatim-shaped versions of the ones that actually inflated the count.
printf -- '- [ ] one\n- [ ] two\n- [x] three\n' > "$R/SUITE_TODO.md"
printf -- '**Then guard it.** a column-0 `- [x]` in SUITE_TODO.md is always the stub bug\n' >> "$R/SUITE_TODO.md"
printf -- '  **The arithmetic.** it counts `[ ]` bullets across BOTH trackers with no dedup\n' >> "$R/SUITE_TODO.md"
printf -- '- [x] archived-one\n' > "$R/SUITE_TODO_DONE.md"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -qE '2 tasks to do · 2 finished' \
  && ok "bold prose containing a checkbox is not counted (2 to do · 2 finished)" \
  || bad "prose line inflated a counter — the loose regex is back" "$OUT"
# …and the anchored form must not UNDER-count: indented sub-bullets are legitimate items and still count.
printf -- '  - [x] a legitimate indented sub-item\n' >> "$R/SUITE_TODO_DONE.md"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -qE '2 tasks to do · 3 finished' \
  && ok "indented sub-bullets still count (no under-counting)" || bad "anchoring dropped a real item" "$OUT"
printf -- '- [ ] one\n- [ ] two\n- [x] three\n' > "$R/SUITE_TODO.md"
rm -f "$R/SUITE_TODO_DONE.md"

echo "[1] not running -> says so, and says how to start it"
OUT="$(RUNNING=0 SUPERVISED=0 run)"
printf '%s' "$OUT" | grep -q 'Not running' && printf '%s' "$OUT" | grep -q 'daemon.sh' \
  && ok "stopped state names the fix" || bad "stopped state wrong" "$OUT"

echo "[2] running with no idle marker -> Working now"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Working now' && ok "working state" || bad "working state wrong" "$OUT"
# ⛔ REGRESSION GUARD, and an INVERTED assertion — it used to require the opposite (2026-08-10).
# The state line must NOT claim how long it has been on the current task. `engine.lock` is a
# mutual-exclusion LEASE that the daemon heartbeats every 60s for the child's whole lifetime, so its mtime
# means "since the last tick", never "since the task began": it printed "1 second into its current task"
# beside a 12-minute-old commit, and was structurally incapable of ever exceeding 60s — so it could never
# show the wedged session it was added to reveal. The assertion it replaces passed ONLY because this test
# hand-backdated the lock 2 hours, which production cannot do. That backdating is kept below on purpose:
# even a 2-hour-old lock must not resurrect the claim.
#
# ⚠️ KEYED ON THE DATA SOURCE, NOT ON THE WORDING — deliberately, and this matters. An earlier draft of this
# guard asserted the absence of the PHRASE "into its current task". That would have gone RED on the very fix
# the ⛔ note in status-digest.sh sanctions: a session-start stamp written once at acquire time renders a
# TRUE "Working now — 3 hours into its current task", and since `status-proof` is a HARD health-gate step
# (health-gate.sh:220) the gate would have parked the daemon and told the implementer to revert correct work.
# What is actually forbidden is deriving a duration from the LEASE. So: (a) the renderer must not read
# engine.lock at all, and (b) a backdated lease must not surface as a duration. A future session-start stamp
# passes both, because this harness never creates one.
touch -t "$(date -v-2H '+%Y%m%d%H%M' 2>/dev/null || date -d '2 hours ago' '+%Y%m%d%H%M')" "$S/engine.lock"
# The backdating is the guard's whole premise, so prove it took effect. If both `date` forms fail (non-BSD,
# non-GNU, or a PATH stub) the substitution is empty, `touch -t ""` errors, and NO lock is created — and with
# `set -uo pipefail` and no `-e` this harness would sail on, silently degrading to the no-lock case below and
# reporting a green that proved nothing about the 2-hour input.
[ -f "$S/engine.lock" ] && ok "the 2-hour backdated lease exists (guard premise holds)" \
  || bad "backdating engine.lock FAILED — every assertion below it is now vacuous" "date -v-2H and date -d both unusable?"
OUT="$(RUNNING=1 run)"
# (a) source: no non-comment line of the renderer may touch the lease. Report the offending line, not a blank.
OFFENDS="$(grep -vE '^[[:space:]]*#' "$DIGEST" | grep -n 'engine\.lock' || true)"
[ -n "$OFFENDS" ] \
  && bad "status-digest.sh reads engine.lock again — it is a heartbeat LEASE; see the ⛔ note in STATE 1" "$OFFENDS" \
  || ok "renderer never reads engine.lock (only the ⛔ comment mentions it)"
# (b) behaviour: a 2-hour-old lease must not surface as a duration anywhere in the output.
printf '%s' "$OUT" | grep -qE '2 hours|119 min|120 min' \
  && bad "the lease's age is being rendered as a duration again" "$OUT" \
  || ok "a 2-hour-old lease surfaces no duration"
printf '%s' "$OUT" | grep -q 'Working now' && ok "still reports the working state" || bad "working state lost" "$OUT"
# Housekeeping, not an assertion: leave no backdated lease for the sections below. The old
# "degrades with no lock file" check that used to live here is GONE on purpose — with the renderer no longer
# opening the file, it re-tested the no-lock state already asserted at the top of [2].
rm -f "$S/engine.lock"

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
printf '%s' "$OUT" | grep -qi 'no eligible work is queued' && ok "idle-no-work state" || bad "idle-no-work wrong" "$OUT"
printf '%s' "$OUT" | grep -qi 'Paused' && bad "claims throttled with no 429 present" "$OUT" || ok "does not invent a cap"
write_plan "" "" "- [ ] **W99.ready — ordinary runnable task**"
printf '2026-08-19 00:00:00  session (rc=1) died after only 4s with NO rate-limit event — NOT a usage limit. Check the session log.\n' > "$S/daemon.log"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Waiting to retry — runnable work remains' && ok "runnable queue changes the idle headline" || bad "runnable work still reads empty" "$OUT"
printf '%s' "$OUT" | grep -q 'died after only 4s' && ok "runnable queue keeps the daemon-log backoff reason" || bad "backoff reason was discarded" "$OUT"
write_plan "" ""
: > "$S/daemon.log"
rm -f "$S/idle.since"

echo "[4b] an active daemon session with an unpushed worktree checkpoint is WORKING, not stale-idle"
A="$T/suite-wt-status-active"; git -C "$R" worktree add -q -b wt/status-active "$A"
printf 'checkpoint\n' > "$A/checkpoint"
git -C "$A" add checkpoint; git -C "$A" commit -qm 'fix(ops): W21.status-idle checkpoint'
echo "$(( $(date +%s) - 7200 ))" > "$S/idle.since"
export SESSION=1
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'Working on W21.status-idle' && ok "live session + ahead worktree names its item" || bad "active worktree was hidden by stale idle" "$OUT"
printf '%s' "$OUT" | grep -q 'checkpoint ahead of the primary checkout' && ok "active state explains its evidence" || bad "active state omitted checkpoint evidence" "$OUT"
printf '%s' "$OUT" | grep -qi 'waiting to retry\|no eligible work' && bad "active state still reads idle" "$OUT" || ok "active state takes precedence over idle stamp"
export SESSION=0
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -qi 'no eligible work is queued' && ok "an ahead worktree without the daemon session does not fake liveness" || bad "checkpoint alone faked liveness" "$OUT"
unset SESSION
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
# W32.needs-you-blind — the Daemon Report fixture must use the shape the section ACTUALLY uses (`### <date>`
# H3 headers). It used to say `- [ ] decide this thing`, a shape that has never appeared in the section or in
# 338 KB of its archive — so this assertion passed while the renderer was structurally blind to every real
# entry. A fixture that models a format the code never meets is how that hole stayed green.
write_plan "- [ ] held thing" "### 2026-08-12 — decide this thing" "- [ ] **W99.ready — ordinary runnable task**"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'held back for you' && bad "hold queue blamed despite runnable work" "$OUT" || ok "runnable work suppresses the unrelated hold-queue blame"
printf '%s' "$OUT" | grep -q 'not been walked through' && ok "daemon-report count surfaced" || bad "daemon report missed" "$OUT"
# Only an actually exhausted resolver result lets a held item become an owner ask. This is an all-blocked
# queue rather than a missing queue, so the proof reaches next-queue-item.sh's real dependency result (rc 4).
write_plan "- [ ] held thing" "" "- [ ] **W99.blocked — waits for its prerequisite** (blocked-on: W98.missing)"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q 'held back for you' && ok "hold queue surfaced only when no runnable work remains" || bad "exhausted queue did not surface its hold" "$OUT"
# …and the scan must STOP at the newest walkthrough marker, so settled entries are never re-raised
# (root CLAUDE.md is emphatic about that). One entry above the marker, one below -> exactly 1 reported.
write_plan "" "### 2026-08-13 — unwalked one

### ✅ 2026-08-12 walkthrough done

### 2026-08-11 — already settled, must NOT be re-raised"
OUT="$(RUNNING=1 run)"
printf '%s' "$OUT" | grep -q '1 Daemon Report entr' \
  && ok "counts only entries ABOVE the newest walkthrough marker" || bad "settled entries re-raised" "$OUT"
OUT="$(RUNNING=1 TASKPORT=1 run)"
printf '%s' "$OUT" | grep -q 'security setting is still relaxed' && ok "taskport surfaced" || bad "taskport missed" "$OUT"
write_plan "" ""

echo "[9] a '## ' heading inside Daemon Report ends the scan (documented trap — must not silently empty)"
printf 'RUN STATUS: x\n\n## Daemon Report\n## Oops\n### 2026-08-12 — hidden\n' > "$P"
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
