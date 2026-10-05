#!/usr/bin/env bash
# prove-codex-agent.sh — the daemon's `--agent codex` lane (owner, 2026-10-04), against a stub `codex`.
#
# WHAT IT PROVES: with AGENT=codex the REAL daemon launches `codex exec` (never claude) with the flags the lane
# depends on, the codex preamble ahead of the resume prompt in ONE argv element, stdin closed, and the
# unattended environment; that it reads the usage window from the session's ROLLOUT file and waits for the
# reset; that a codex limit error is reported as a usage limit, not as an empty queue; that the agent can come
# from $STATE/agent (what a launchd relaunch reads); and that a bad agent or a missing preamble refuses to start.
# Sandboxed like prove-daemon.sh: its own HOME, STATE, CODEX_HOME and git REPO, host commands stubbed.
#
# USAGE:  ops/autonomous/tests/prove-codex-agent.sh [path/to/archive-suite-autonomous.sh]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DAEMON="${1:-$HERE/../archive-suite-autonomous.sh}"
[ -f "$DAEMON" ] || { echo "no daemon at $DAEMON"; exit 2; }
T="$(mktemp -d)"
reap() {
  [ -f "$T/daemon.pids" ] || return 0
  while read -r p; do case "$(ps -p "$p" -o command= 2>/dev/null)" in *"$DAEMON"*) kill -9 "$p" 2>/dev/null ;; esac; done < "$T/daemon.pids"
}
trap 'reap; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

unset AUTONOMOUS_AGENT   # an inherited value would override every scenario below (2026-10-04 review)
export HOME="$T/home"; mkdir -p "$HOME/Desktop" "$HOME/.local/bin"
BIN="$T/bin"; mkdir -p "$BIN"
for c in security osascript launchctl caffeinate curl; do printf '#!/bin/sh\nexit 0\n' > "$BIN/$c"; chmod +x "$BIN/$c"; done
cat > "$BIN/df" <<'STUB'
#!/bin/sh
echo "Filesystem 1M-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk1 1000000 1000 999999 1% 1 1 0% /"
STUB
chmod +x "$BIN/df"
export PATH="$BIN:$PATH"

REPO="$T/repo with space"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
echo seed > "$REPO/f"; printf -- '- [ ] todo one\n' > "$REPO/SUITE_TODO.md"
git -C "$REPO" add -A; git -C "$REPO" commit -qm seed
git -C "$REPO" branch -f main 2>/dev/null; git -C "$REPO" update-ref refs/remotes/origin/main HEAD
PLAN="$T/plan.md"
cat > "$PLAN" <<'EOF'
RUN STATUS: IN_PROGRESS — test

## WORK QUEUE (priority order)
- [ ] item one

## Session Log
EOF

STATE="$T/state"; mkdir -p "$STATE"
printf 'autonomous maintenance session for the Archive Suite (prove-codex fixture prompt)\n' > "$STATE/resume-prompt.txt"
printf 'YOU ARE RUNNING UNDER CODEX (prove-codex fixture preamble)\n' > "$STATE/codex-preamble.txt"
export CODEX_HOME="$T/codexhome"; mkdir -p "$CODEX_HOME/sessions/2026/10/04"

# The stub codex. $CTRL: "<rc>:<pct or none>:<reset offset s>:<limit-error yes|no>[:<grow|silent>:<seconds>]".
# grow = stay quiet on stdout but append to the rollout every second (a codex session thinking or delegating);
# silent = stay quiet everywhere (a wedged session).
CTRL="$T/ctrl"; ARGV="$T/argv"; CHILDENV="$T/childenv"; STDIN="$T/stdin"
cat > "$T/codex" <<STUB
#!/usr/bin/env bash
: > "$ARGV"; for a in "\$@"; do printf '%s\n----\n' "\$a" >> "$ARGV"; done
env > "$CHILDENV"
if [ -t 0 ]; then echo tty > "$STDIN"; else cat > "$STDIN.content"; echo notty > "$STDIN"; fi
IFS=: read -r rc pct off lim hold hsecs < "$CTRL"
tid="tid-\$(date +%s)-\$\$"
echo '{"type":"thread.started","thread_id":"'"\$tid"'"}'
if [ "\$pct" != none ]; then
  rr=\$(( \$(date +%s) + off ))
  echo '{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":'"\$pct"'.0,"window_minutes":300,"resets_at":'"\$rr"'},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":'"\$((rr+99999))"'},"credits":null}}}' \
    > "$CODEX_HOME/sessions/2026/10/04/rollout-2026-10-04T00-00-00-\$tid.jsonl"
fi
# A transient retry notice, as the real CLI emits inside sessions that then succeed: must not read as a failure.
echo '{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion)"}'
echo '{"type":"turn.started"}'
roll="$CODEX_HOME/sessions/2026/10/04/rollout-2026-10-04T00-00-00-\$tid.jsonl"
case "\$hold" in
  grow)   for _ in \$(seq 1 "\$hsecs"); do sleep 1; echo '{"type":"response_item","payload":{"type":"reasoning"}}' >> "\$roll"; done ;;
  silent) sleep "\$hsecs" ;;
esac
if [ "\$lim" = yes ]; then
  echo '{"type":"turn.failed","error":{"message":"You have hit your usage limit. Try again later."}}'
else
  echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"stub done"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}'
fi
exit "\$rc"
STUB
chmod +x "$T/codex"
printf '#!/bin/sh\necho CLAUDE-WAS-CALLED >> "%s"\nexit 1\n' "$T/claude.calls" > "$T/claude"; chmod +x "$T/claude"
printf '#!/bin/sh\necho STATUS-OK\n' > "$T/status-stub.sh"; chmod +x "$T/status-stub.sh"

launch() {   # $1 = AUTONOMOUS_AGENT value ("" = unset)
  env -u AUTONOMOUS_AGENT ${1:+AUTONOMOUS_AGENT="$1"} CODEX_THREAD_ID=leaked-parent CODEX_SANDBOX=seatbelt \
  AUTONOMOUS_HB_STALL="${HB_STALL:-600}" AUTONOMOUS_HB_IDLE_N=2 AUTONOMOUS_YIELD_CMD="${YIELD_CMD:-$T/no-yield}" \
  AUTONOMOUS_LABEL=provecodex AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" AUTONOMOUS_STATE="$STATE" \
  AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_CODEX="$T/codex" \
  AUTONOMOUS_INTERVAL=1 AUTONOMOUS_MAXBACKOFF=2 AUTONOMOUS_IDLE_STOP=0 AUTONOMOUS_MAX_NOCOMPLETE=0 \
  AUTONOMOUS_GATE_EVERY=0 AUTONOMOUS_STATUS_CMD="$T/status-stub.sh" AUTONOMOUS_COMPACTOR="$T/none" \
  AUTONOMOUS_DOC_PREGATE=0 AUTONOMOUS_BUDGET_CMD="$T/none" AUTONOMOUS_HB_POLL=1 \
  AUTONOMOUS_USAGE_CMD="$HERE/../usage-window.sh" AUTONOMOUS_WINDOW_POLL=1 AUTONOMOUS_WINDOW_SLACK=0 \
    bash "$DAEMON" >"$T/daemon.out" 2>&1 &
  local pid=$!; echo "$pid" >> "$T/daemon.pids"; echo "$pid"
}
# Also end any stub session still running: the daemon's TERM trap exits without killing its child, and an
# orphaned `grow` stub would keep writing a rollout into the NEXT scenario (it did, and masked [6]'s kill).
stop() { kill -TERM "$1" 2>/dev/null; wait "$1" 2>/dev/null; pkill -f "$T/codex" 2>/dev/null; sleep 0.3; }
reset() { : > "$STATE/daemon.log"; rm -f "$STATE/usage-window.last" "$STATE/usage-window.tsv" "$STATE/idle.since" \
          "$STATE/engine.lock" "$STATE/agent" "$T/claude.calls" "$ARGV" "$STDIN"; rm -rf "$CODEX_HOME/sessions/2026/10/04"/*; }
L="$STATE/daemon.log"

echo "[1] AUTONOMOUS_AGENT=codex launches codex exec, never claude"
reset; echo "0:40:3600:no" > "$CTRL"; P=$(launch codex); sleep 6; stop "$P"
grep -q 'daemon up (pid [0-9]*, agent codex' "$L" && ok "daemon logs agent codex" || bad "no 'agent codex' in the up line"
[ -s "$ARGV" ] && ok "codex stub ran" || bad "codex stub never ran: $(tail -3 "$L")"
[ ! -e "$T/claude.calls" ] && ok "claude never called" || bad "claude was called under AGENT=codex"
[ "$(sed -n 1p "$ARGV")" = exec ] && ok "first argument is 'exec'" || bad "argv[1] is '$(sed -n 1p "$ARGV")'"
for f in --json --approve-for-me --add-dir; do grep -qx -- "$f" "$ARGV" && ok "passes $f" || bad "missing $f"; done
grep -qx -- "$STATE" "$ARGV" && ok "state dir is writable (--add-dir)" || bad "state dir not passed to --add-dir"
grep -qx -- "$T" "$ARGV" && ok "the repo's parent is writable, for sibling worktrees" || bad "repo parent not passed to --add-dir"
grep -q -- 'dangerously' "$ARGV" && bad "a --dangerously flag was passed" || ok "no --dangerously flag"
grep -qx -- 'model_reasoning_effort=medium' "$ARGV" && ok "effort passed as model_reasoning_effort=medium" || bad "effort not passed"
# The prompt: preamble first, then the resume prompt, in ONE argument (what `daemon.sh stop` matches).
awk 'BEGIN{RS="\n----\n"} /YOU ARE RUNNING UNDER CODEX/ && /autonomous maintenance session for the Archive Suite/ {f=1}
     END{exit !f}' "$ARGV" && ok "preamble + resume prompt are one argument" || bad "prompt not one argument with both parts"
awk 'BEGIN{RS="\n----\n"} /autonomous maintenance session/ { exit !(index($0,"YOU ARE RUNNING UNDER CODEX") < index($0,"autonomous maintenance session")) }' "$ARGV" \
  && ok "preamble comes before the resume prompt" || bad "preamble is not first"
# (Non-interactive bash already gives a background job /dev/null as stdin, so this holds even without the
# daemon's explicit `< /dev/null`: a mutant removing it survives as an EQUIVALENT mutant, checked 2026-10-04.
# The redirect stays because the property matters — a foreground `codex exec` waits on its stdin.)
[ "$(cat "$STDIN" 2>/dev/null)" = notty ] && [ ! -s "$STDIN.content" ] && ok "stdin is closed (empty, not a terminal)" || bad "stdin was '$(cat "$STDIN" 2>/dev/null)'"
grep -q '^ARCHIVE_UNATTENDED=1$' "$CHILDENV" && ok "ARCHIVE_UNATTENDED=1 reaches the session" || bad "ARCHIVE_UNATTENDED missing"
grep -q '^AUTONOMOUS_AGENT=' "$CHILDENV" && bad "AUTONOMOUS_AGENT exported to the session (it leaks into the gate)" || ok "AUTONOMOUS_AGENT not exported to the session"
grep -q '^CODEX_THREAD_ID=\|^CODEX_SANDBOX=' "$CHILDENV" && bad "a parent CODEX_* variable leaked into the session" || ok "parent CODEX_* variables scrubbed"
grep -q "^CODEX_HOME=$CODEX_HOME\$" "$CHILDENV" && ok "CODEX_HOME kept" || bad "CODEX_HOME was dropped"
grep -q 'ops/autonomous/bin' <(grep '^PATH=' "$CHILDENV") && ok "GUI shims first on PATH" || bad "GUI shims not on PATH"
grep -q 'turns, ended completed' "$L" && ok "session outcome logged from the codex events" || bad "outcome not logged: $(grep 'session cost' "$L" | tail -1)"
[ "$(cat "$STATE/last-session.txt" 2>/dev/null)" = "stub done" ] && ok "last agent message mirrored to last-session.txt" || bad "last-session.txt is '$(cat "$STATE/last-session.txt" 2>/dev/null)'"
grep -q '^40 ' "$STATE/usage-window.last" 2>/dev/null && ok "window reading taken from the rollout file (40%)" || bad "usage-window.last is '$(cat "$STATE/usage-window.last" 2>/dev/null)'"

echo "[2] a window at 97% makes the next cycle wait for the reset"
# The reset is 60 s out, not 4: on a busy machine (the health gate runs this beside a VM) a 4 s window had already
# reset before the next cycle looked, so nothing waited and the check failed (2026-10-05 gate). Stopping the
# daemon mid-wait is fine: the wait polls every second.
reset; echo "1:97:60:no" > "$CTRL"; P=$(launch codex); sleep 9; stop "$P"
grep -q 'usage window 97% used.*waiting until' "$L" && ok "waits for the reset" || bad "no wait: $(grep -E 'usage|session' "$L" | tail -4)"
[ "$(grep -c 'launching fresh' "$L")" -le 3 ] && ok "does not hammer the window ($(grep -c 'launching fresh' "$L") launches in 9 s)" || bad "too many launches"

echo "[2b] the owner's own Codex use counts: a newer rollout from another session at 98% also makes it wait"
reset; echo "0:30:3600:no" > "$CTRL"
echo '{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":98.0,"window_minutes":300,"resets_at":'"$(( $(date +%s) + 60 ))"'},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":'"$(( $(date +%s) + 99999 ))"'}}}' \
  > "$CODEX_HOME/sessions/2026/10/04/rollout-owner-interactive.jsonl"
touch -t "$(date -v+1H '+%Y%m%d%H%M.%S')" "$CODEX_HOME/sessions/2026/10/04/rollout-owner-interactive.jsonl"   # newest of all
P=$(launch codex); sleep 6; stop "$P"
grep -q 'usage window 98% used.*waiting until' "$L" && ok "waits on the account-wide reading, not just its own session's" || bad "ignored the newer reading: $(grep -E 'usage|launching' "$L" | tail -3)"

echo "[2c] usage-window.sh: a session's no-argument call reads codex's window when \$STATE/agent says codex"
reset; echo codex > "$STATE/agent"
echo '{"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":61.0,"window_minutes":300,"resets_at":'"$(( $(date +%s) + 3600 ))"'},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":'"$(( $(date +%s) + 99999 ))"'}}}' \
  > "$CODEX_HOME/sessions/2026/10/04/rollout-a.jsonl"
touch -t "$(date -v-10M '+%Y%m%d%H%M.%S')" "$CODEX_HOME/sessions/2026/10/04/rollout-a.jsonl"
echo '{"rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"credits":null}}' > "$CODEX_HOME/sessions/2026/10/04/rollout-b.jsonl"
out="$(AUTONOMOUS_STATE="$STATE" bash "$HERE/../usage-window.sh" --raw)"
[ "${out%% *}" = 61 ] && ok "no-argument call reads the codex rollout" || bad "no-argument call gave '$out'"
out="$(bash "$HERE/../usage-window.sh" --raw --codex-latest)"
[ "${out%% *}" = 61 ] && ok "a newer premium-only rollout does not hide the codex reading" || bad "--codex-latest gave '$out'"
rm -f "$STATE/agent"
out="$(AUTONOMOUS_STATE="$STATE" bash "$HERE/../usage-window.sh" --raw)"; rc=$?
[ "$rc" = 3 ] && ok "under claude the no-argument call still reads the session log" || bad "claude no-arg call gave '$out' rc=$rc"

echo "[3] a codex limit error is a USAGE LIMIT, not an empty queue"
reset; echo "1:none:0:yes" > "$CTRL"; P=$(launch codex); sleep 4; stop "$P"
grep -q 'hit a USAGE LIMIT (codex' "$L" && ok "reported as a usage limit" || bad "not reported as a limit: $(grep 'session (rc' "$L" | tail -2)"
grep -q 'advanced nothing' "$L" && bad "also reported as 'advanced nothing'" || ok "not reported as an idle queue"

echo "[4] the agent comes from \$STATE/agent when the environment does not set it (a launchd relaunch)"
reset; echo "0:30:3600:no" > "$CTRL"; echo codex > "$STATE/agent"; P=$(launch ""); sleep 4; stop "$P"
grep -q 'agent codex' "$L" && [ -s "$ARGV" ] && ok "\$STATE/agent=codex is honoured" || bad "state file ignored: $(head -2 "$L")"
reset; P=$(launch ""); sleep 4; stop "$P"
grep -q 'agent claude' "$L" && [ -e "$T/claude.calls" ] && ok "no file, no env -> claude (the default)" || bad "default is not claude: $(head -2 "$L")"

echo "[6] watchdog: a codex session quiet on stdout but writing its rollout is spared; one silent everywhere is not"
reset; echo "0:30:3600:no:grow:9" > "$CTRL"; P=$(HB_STALL=3 launch codex); sleep 13; stop "$P"
grep -q 'watchdog:' "$L" && bad "killed a session whose rollout was growing: $(grep 'watchdog:' "$L" | head -1)" || ok "growing rollout keeps the session alive"
grep -q 'turns, ended completed' "$L" && ok "…and it ran to completion" || bad "session did not complete: $(grep 'session' "$L" | tail -2)"
reset; echo "0:30:3600:no:silent:20" > "$CTRL"; P=$(HB_STALL=3 launch codex); sleep 12; stop "$P"
grep -q 'watchdog:' "$L" && ok "silent session killed by the watchdog" || bad "silent session never killed: $(cat "$L")"

echo "[7] yield (owner, 2026-10-04): no gate or session while the priority project says so; resumes after"
# The detail in brackets changes on every call, as the real one's page label does: still logged once.
printf '#!/bin/sh\n[ -f "%s" ] && { echo "Vision OCR is running a model job (stub page $(date +%%s%%N))"; exit 0; }\nexit 1\n' "$T/yield.on" > "$T/yield-stub"; chmod +x "$T/yield-stub"
reset; echo "0:30:3600:no" > "$CTRL"; touch "$T/yield.on"; P=$(YIELD_CMD="$T/yield-stub" launch codex); sleep 4
[ ! -s "$ARGV" ] && ok "no session while yielding" || bad "a session started while yielding"
[ "$(grep -c 'yielding — Vision OCR is running a model job (stub page' "$L")" = 1 ] && ok "yield logged once, not every cycle, though its detail changes" || bad "yield log count $(grep -c yielding "$L")"
[ ! -f "$STATE/idle.since" ] && ok "a yield is not idleness (no idle stopwatch)" || bad "idle.since set while yielding"
rm -f "$T/yield.on"; sleep 4; stop "$P"
grep -q 'yield over' "$L" && [ -s "$ARGV" ] && ok "session starts once the yield ends" || bad "no session after the yield ended: $(tail -3 "$L")"

echo "[5] refusals"
refusal_rc() {   # $1 = agent; runs the daemon in THIS shell (not a $(…) subshell) so its exit code is waitable
  env AUTONOMOUS_AGENT="$1" AUTONOMOUS_LABEL=provecodex AUTONOMOUS_REPO="$REPO" AUTONOMOUS_PLAN="$PLAN" \
    AUTONOMOUS_STATE="$STATE" AUTONOMOUS_CLAUDE="$T/claude" AUTONOMOUS_CODEX="$T/codex" \
    bash "$DAEMON" >"$T/daemon.out" 2>&1 &
  local p=$!; echo "$p" >> "$T/daemon.pids"; sleep 2
  if kill -0 "$p" 2>/dev/null; then kill -TERM "$p"; wait "$p" 2>/dev/null; echo running; else wait "$p"; echo "$?"; fi
}
reset; rc="$(refusal_rc gpt)"
[ "$rc" = 2 ] && grep -q "unknown agent 'gpt'" "$T/daemon.out" && ok "unknown agent refuses to start (exit 2)" || bad "unknown agent: rc=$rc $(cat "$T/daemon.out")"
mv "$STATE/codex-preamble.txt" "$T/preamble.bak"; reset; rc="$(refusal_rc codex)"
[ "$rc" = 2 ] && grep -q 'codex preamble missing' "$T/daemon.out" && ok "missing preamble refuses to start (exit 2)" || bad "missing preamble: rc=$rc $(cat "$T/daemon.out")"
mv "$T/preamble.bak" "$STATE/codex-preamble.txt"

echo ""
echo "=================== $PASS passed, $FAIL failed ==================="
[ "$FAIL" = 0 ]
